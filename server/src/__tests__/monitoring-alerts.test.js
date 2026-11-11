import { describe, expect, it, vi } from 'vitest';
import { createMonitoringService } from '../lib/monitoring.js';
import {
    createMonitoringAlerts,
    getMonitoringAlertConfig,
    monitoringAlertsFromEnvironment,
} from '../lib/monitoring-alerts.js';

const HOUR = 60 * 60 * 1000;

function harness({ send = vi.fn(async () => ({ ok: true })), repeatMs = 6 * HOUR } = {}) {
    let now = Date.parse('2026-11-11T12:00:00Z');
    const clock = () => new Date(now);
    const state = { status: 'ok', message: 'Storage has enough free space' };
    const monitoring = createMonitoringService({
        checks: [{
            id: 'source-space', label: 'Original <storage>', category: 'storage',
            collect: async () => ({ ...state }),
        }],
        clock,
    });
    const alerts = createMonitoringAlerts({ send, repeatMs, clock });
    monitoring.registerCheck(alerts.check);
    monitoring.subscribe(alerts.notify);
    return {
        monitoring, send, state,
        advance(ms) { now += ms; },
        delivery: () => monitoring.snapshot().checks.find(check => check.id === 'alert-delivery'),
    };
}

describe('monitoring alerts', () => {
    it('alerts on transitions, repeats unresolved problems, and reports recovery', async () => {
        const h = harness();
        await h.monitoring.runOnce();
        expect(h.send).not.toHaveBeenCalled();

        Object.assign(h.state, { status: 'warning', message: 'Storage has reached a warning threshold' });
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(1);
        expect(h.send.mock.calls[0][0]).toContain('*Original &lt;storage&gt;*: WARNING — Storage has reached a warning threshold');

        h.advance(6 * HOUR - 1);
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(1);
        h.advance(1);
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(2);

        h.state.status = 'critical';
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(3);
        expect(h.send.mock.calls[2][0]).toContain('CRITICAL');

        h.state.status = 'ok';
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(4);
        expect(h.send.mock.calls[3][0]).toContain('*Original &lt;storage&gt;*: recovered');
        await h.monitoring.runOnce();
        expect(h.send).toHaveBeenCalledTimes(4);
    });

    it.each([
        ['rejected delivery', vi.fn().mockResolvedValueOnce({ ok: false, error: 'not_in_channel' })],
        ['thrown delivery', vi.fn().mockRejectedValueOnce(new Error('network'))],
    ])('retries after a %s and surfaces it on the dashboard', async (_label, send) => {
        send.mockResolvedValue({ ok: true });
        const h = harness({ send });
        h.state.status = 'critical';
        await h.monitoring.runOnce();
        expect(send).toHaveBeenCalledTimes(1);

        await h.monitoring.runOnce();
        expect(h.delivery()).toMatchObject({ status: 'critical' });
        expect(send).toHaveBeenCalledTimes(2);
        expect(send.mock.calls[1][0]).toContain('CRITICAL');

        await h.monitoring.runOnce();
        expect(h.delivery()).toMatchObject({ status: 'ok' });
        expect(send).toHaveBeenCalledTimes(2);
    });

    it('does not alert about its own delivery check', async () => {
        const send = vi.fn(async () => ({ ok: true }));
        const alerts = createMonitoringAlerts({ send, repeatMs: HOUR });
        await alerts.notify({
            checkedAt: 'now',
            checks: [{ id: 'alert-delivery', label: 'Monitoring alerts', status: 'critical', message: 'failed' }],
        });
        expect(send).not.toHaveBeenCalled();
    });
});

describe('monitoring alert configuration', () => {
    it('is disabled without a channel and validates settings', () => {
        expect(getMonitoringAlertConfig({})).toEqual({ enabled: false });
        expect(getMonitoringAlertConfig({ DVU_MONITOR_ALERT_SLACK_CHANNEL: 'ops-alerts' }))
            .toEqual({ enabled: true, channel: 'ops-alerts', repeatMs: 6 * HOUR });
        expect(getMonitoringAlertConfig({
            DVU_MONITOR_ALERT_SLACK_CHANNEL: 'ops', DVU_MONITOR_ALERT_REPEAT_HOURS: '168',
        }).repeatMs).toBe(168 * HOUR);
        for (const channel of ['#ops', 'Ops', 'ops alerts']) {
            expect(() => getMonitoringAlertConfig({ DVU_MONITOR_ALERT_SLACK_CHANNEL: channel })).toThrow('channel');
        }
        for (const hours of ['0', '169', '1.5', 'x']) {
            expect(() => getMonitoringAlertConfig({
                DVU_MONITOR_ALERT_SLACK_CHANNEL: 'ops', DVU_MONITOR_ALERT_REPEAT_HOURS: hours,
            })).toThrow('REPEAT_HOURS');
        }
    });

    it.each([
        ['an invalid channel', { DVU_MONITOR_ALERT_SLACK_CHANNEL: '#ops' }, true, 'configuration is invalid'],
        ['missing Slack credentials', { DVU_MONITOR_ALERT_SLACK_CHANNEL: 'ops' }, false, 'without Slack delivery'],
    ])('shows a critical dashboard check for %s', async (_label, env, configured, message) => {
        const monitoring = createMonitoringService();
        const slack = { isConfigured: () => configured, postToChannel: vi.fn() };
        expect(monitoringAlertsFromEnvironment({ env, monitoring, slack })).toEqual({ enabled: false });
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks).toEqual([expect.objectContaining({
            id: 'alert-delivery', status: 'critical', message: expect.stringContaining(message),
        })]);
        expect(slack.postToChannel).not.toHaveBeenCalled();
    });

    it('delivers alerts to the configured channel', async () => {
        const monitoring = createMonitoringService({
            checks: [{
                id: 'original-b2', label: 'Original backup: B2', category: 'backup',
                collect: async () => ({ status: 'critical', message: 'The last successful backup is stale' }),
            }],
        });
        const slack = { isConfigured: () => true, postToChannel: vi.fn(async () => ({ ok: true })) };
        expect(monitoringAlertsFromEnvironment({
            env: { DVU_MONITOR_ALERT_SLACK_CHANNEL: 'ops-alerts' }, monitoring, slack,
        })).toEqual({ enabled: true });
        await monitoring.runOnce();
        expect(slack.postToChannel).toHaveBeenCalledWith(
            'ops-alerts', expect.stringContaining('*Original backup: B2*: CRITICAL'),
        );
    });
});
