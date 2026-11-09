import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { AssetList } from "@/components/AssetList";
import type { Asset } from "@/lib/types";

const muxUrl = "https://image.mux.com/playback-123/thumbnail.png?width=640&time=2";
const listUrl = "https://image.mux.com/playback-123/thumbnail.webp?width=320&time=2&fit_mode=smartcrop";

function video(overrides: Partial<Asset> = {}): Asset {
  return {
    id: "asset-1",
    status: "READY",
    moderation: "ACTIVE",
    mediaPlaybackUnavailable: false,
    mediasourceId: "10001",
    formResponse: { id: "form-1", slug: "Thumbnail story" },
    clips: [{ id: "clip-1", thumbnailUrl: muxUrl }],
    ...overrides,
  };
}

function list(asset: Asset) {
  return <AssetList assets={[asset]} isLoading={false} viewerRole="USER" />;
}

afterEach(cleanup);

describe("asset thumbnails", () => {
  it("uses a lazy, fixed-aspect list-sized Mux image and preserves other parameters", () => {
    const { container } = render(list(video()));
    const image = container.querySelector("img");
    expect(image?.getAttribute("src")).toBe(listUrl);
    expect(image?.getAttribute("loading")).toBe("lazy");
    expect(image?.getAttribute("decoding")).toBe("async");
    expect(image?.getAttribute("alt")).toBe("");
    expect(image?.getAttribute("width")).toBe("320");
    expect(image?.getAttribute("height")).toBe("180");
    expect(image?.parentElement?.className).toContain("aspect-video");
  });

  it("leaves non-Mux thumbnail URLs unchanged", () => {
    const url = "https://image.mux.com.example.test/playback/thumbnail.png?width=640";
    const { container } = render(list(video({ clips: [{ id: "clip-1", thumbnailUrl: url }] })));
    expect(container.querySelector("img")?.getAttribute("src")).toBe(url);
  });

  it("shows indeterminate progress during upload without requesting a thumbnail", () => {
    const { container } = render(list(video({ status: "UPLOADING" })));
    const progress = screen.getByRole("progressbar", { name: "Upload in progress" });
    expect(progress.getAttribute("value")).toBeNull();
    expect(screen.getByText("Uploading")).toBeTruthy();
    expect(container.querySelector("img")).toBeNull();
  });

  it("shows a shimmer while processing and an error tile for failed uploads", () => {
    const { container, rerender } = render(list(video({ status: "PROCESSING" })));
    expect(screen.getByText("Processing")).toBeTruthy();
    expect(container.querySelector(".thumbnail-shimmer")).toBeTruthy();
    expect(container.querySelector("img")).toBeNull();

    rerender(list(video({ status: "ERROR" })));
    expect(screen.getByText("Error")).toBeTruthy();
    expect(container.querySelector("img")).toBeNull();
  });

  it.each([
    ["paused", { moderation: "PAUSED" as const }, "Paused"],
    ["flagged", { moderation: "FLAGGED_FOR_REMOVAL" as const }, "Unavailable"],
    ["removed", { moderation: "REMOVED" as const }, "Unavailable"],
    ["unavailable", { mediaPlaybackUnavailable: true }, "Unavailable"],
    ["reset", { mediaPlaybackReset: true }, "Unavailable"],
    ["uncertain create", { mediaCreateOperationId: "pending" }, "Unavailable"],
  ])("does not render a thumbnail for %s playback", (_state, overrides, label) => {
    const { container } = render(list(video(overrides)));
    expect(container.querySelector("img")).toBeNull();
    expect(screen.getByText(label)).toBeTruthy();
    if (_state === "paused") {
      expect(screen.getByText("PAUSED")).toBeTruthy();
      expect(screen.getByRole("button", { name: /Thumbnail story/ }).parentElement?.className).toContain("opacity-80");
    }
  });

  it("shows a fallback for missing or failed images and retries a changed URL", () => {
    const { container, rerender } = render(list(video({ clips: [{ id: "clip-1", thumbnailUrl: null }] })));
    expect(screen.getByText("No thumbnail")).toBeTruthy();

    rerender(list(video()));
    const image = container.querySelector("img");
    if (!image) throw new Error("Expected the thumbnail image");
    fireEvent.error(image);
    expect(screen.getByText("Image unavailable")).toBeTruthy();
    expect(container.querySelector("img")).toBeNull();

    rerender(list(video({ moderation: "PAUSED", mediaPlaybackUnavailable: true })));
    rerender(list(video()));
    const retried = container.querySelector("img");
    if (!retried) throw new Error("Expected the thumbnail to retry after playback was restored");
    fireEvent.error(retried);
    expect(screen.getByText("Image unavailable")).toBeTruthy();

    const replacement = "https://image.mux.com/new-playback/thumbnail.png?width=640";
    rerender(list(video({ clips: [{ id: "clip-1", thumbnailUrl: replacement }] })));
    expect(container.querySelector("img")?.getAttribute("src"))
      .toBe("https://image.mux.com/new-playback/thumbnail.webp?width=320&fit_mode=smartcrop");
    expect(screen.queryByText("Image unavailable")).toBeNull();
  });
});
