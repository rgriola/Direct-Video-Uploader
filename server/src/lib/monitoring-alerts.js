const CHANNEL = /^[a-z0-9][a-z0-9._-]{0,79}$/;
const ALERT_STATUSES = new Set(['warning', 'critical', 'unknown']);
const MAX_REPEAT_HOURS = 7 * 24;
export const ALERT_DELIVERY_CHECK_ID = 'alert-delivery';

export function getMonitoringAlertConfig(env = process.env) {
    const channel = env.DVU_MONITOR_ALERT_SLACK_CHANNEL;
    if (channel === undefined || channel === '') return { enabled: false };
    if (!CHANNEL.test(channel)) {
        throw new Error('DVU_MONITOR_ALERT_SLACK_CHANNEL must be a lowercase Slack channel name without #');
    }
    const repeat = env.DVU_MONITOR_ALERT_REPEAT_HOURS || '6';
    if (!/^[1-9][0-9]*$/.test(repeat) || Number(repeat) > MAX_REPEAT_HOURS) {
        throw new Error(`DVU_MONITOR_ALERT_REPEAT_HOURS must be between 1 and ${MAX_REPEAT_HOURS}`);
    }
    return { enabled: true, channel, repeatMs: Number(repeat) * 60 * 60 * 1000 };
}

function escapeSlack(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function deliveryCheck(result) {
    return {
        id: ALERT_DELIVERY_CHECK_ID,
        label: 'Monitoring alerts',
        category: 'service',
        collect: async () => ({ ...result() }),
    };
}

// Alerts are sent while the server runs; they cannot report a stopped server or host.
export function createMonitoringAlerts({ send, repeatMs, clock = () => new Date(), log }) {
    if (typeof send !== 'function' || !Number.isSafeInteger(repeatMs) || repeatMs <= 0) {
        throw new TypeError('Monitoring alerts need a sender and a positive repeat interval');
    }
    const notified = new Map();
    let delivery = { status: 'ok', message: 'No monitoring alert has been required' };

    async function notify(snapshot) {
        const now = clock().getTime();
        const checks = (snapshot?.checks ?? []).filter(check => check.id !== ALERT_DELIVERY_CHECK_ID);
        const current = new Set(checks.map(check => check.id));
        for (const id of notified.keys()) {
            if (!current.has(id)) notified.delete(id);
        }

        const lines = [];
        const updates = [];
        for (const check of checks) {
            const previous = notified.get(check.id);
            if (ALERT_STATUSES.has(check.status)) {
                if (!previous || previous.status !== check.status || now - previous.at >= repeatMs) {
                    lines.push(`• *${escapeSlack(check.label)}*: ${check.status.toUpperCase()} — ${escapeSlack(check.message)}`);
                    updates.push([check.id, { status: check.status, at: now }]);
                }
            } else if (previous) {
                lines.push(`• *${escapeSlack(check.label)}*: recovered`);
                updates.push([check.id, null]);
            }
        }
        if (!lines.length) return;

        const text = [`Fixer monitoring (${snapshot.checkedAt ?? 'unknown time'})`, ...lines].join('\n');
        let result;
        try {
            result = await send(text);
        } catch (error) {
            result = { ok: false, error: error?.message };
        }
        if (!result?.ok) {
            delivery = { status: 'critical', message: 'The most recent monitoring alert could not be delivered' };
            log?.error({ errorCode: result?.error }, 'Monitoring alert delivery failed');
            return;
        }
        for (const [id, value] of updates) {
            if (value) notified.set(id, value);
            else notified.delete(id);
        }
        delivery = { status: 'ok', message: 'The most recent monitoring alert was delivered' };
    }

    return { notify, check: deliveryCheck(() => delivery) };
}

export function monitoringAlertsFromEnvironment({
    env = process.env, monitoring, slack, clock, log,
}) {
    let config;
    try {
        config = getMonitoringAlertConfig(env);
    } catch (error) {
        log?.error({ err: { message: error.message } }, 'Monitoring alert configuration is invalid');
        monitoring.registerCheck(deliveryCheck(() => ({
            status: 'critical', message: 'Monitoring alert configuration is invalid',
        })));
        return { enabled: false };
    }
    if (!config.enabled) return { enabled: false };
    if (!slack.isConfigured()) {
        log?.error('Monitoring alerts require SLACK_BOT_TOKEN');
        monitoring.registerCheck(deliveryCheck(() => ({
            status: 'critical', message: 'Monitoring alerts are configured without Slack delivery',
        })));
        return { enabled: false };
    }

    const alerts = createMonitoringAlerts({
        send: text => slack.postToChannel(config.channel, text),
        repeatMs: config.repeatMs,
        clock,
        log,
    });
    monitoring.registerCheck(alerts.check);
    monitoring.subscribe(alerts.notify);
    return { enabled: true };
}
