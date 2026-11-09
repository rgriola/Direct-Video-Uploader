import { useState } from "react";
import type { AssetModeration } from "@/lib/types";
import { Icon, type IconName } from "./Icon";

interface AssetThumbnailProps {
  status: string;
  moderation: AssetModeration;
  playbackAvailable: boolean;
  thumbnailUrl?: string | null;
}

function listThumbnailUrl(url: string): string {
  const mux = url.match(/^(https:\/\/image\.mux\.com\/[^/?#]+\/)thumbnail\.(?:png|jpe?g|webp)(?:\?([^#]*))?(#.*)?$/i);
  if (!mux) return url;

  const params = new URLSearchParams(mux[2] ?? "");
  params.set("width", "320");
  params.set("fit_mode", "smartcrop");
  return `${mux[1]}thumbnail.webp?${params.toString()}${mux[3] ?? ""}`;
}

function ThumbnailStatus({ icon, label }: { icon: IconName; label: string }) {
  return (
    <div className="flex h-full w-full flex-col items-center justify-center gap-1">
      <Icon name={icon} size={16} />
      <span className="text-[10px] leading-none">{label}</span>
    </div>
  );
}

function ThumbnailImage({ src }: { src: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <ThumbnailStatus icon="warning" label="Image unavailable" />;

  return (
    <img
      src={src}
      alt=""
      loading="lazy"
      decoding="async"
      width={320}
      height={180}
      className="h-full w-full object-cover"
      onError={() => setFailed(true)}
    />
  );
}

export function AssetThumbnail({ status, moderation, playbackAvailable, thumbnailUrl }: AssetThumbnailProps) {
  let content;
  if (moderation !== "ACTIVE") {
    content = <ThumbnailStatus icon="locked" label={moderation === "PAUSED" ? "Paused" : "Unavailable"} />;
  } else if (status === "UPLOADING") {
    content = (
      <div className="flex h-full w-full flex-col items-center justify-center gap-1">
        <span className="text-[10px] leading-none">Uploading</span>
        <progress aria-label="Upload in progress" max={100} className="h-1 w-12" />
      </div>
    );
  } else if (status === "PROCESSING") {
    content = (
      <div className="relative h-full w-full overflow-hidden">
        <div aria-hidden="true" className="thumbnail-shimmer absolute inset-0 bg-linear-to-r from-transparent via-(--foreground)/15 to-transparent" />
        <ThumbnailStatus icon="processing" label="Processing" />
      </div>
    );
  } else if (status === "ERROR") {
    content = <ThumbnailStatus icon="error" label="Error" />;
  } else if (!playbackAvailable) {
    content = <ThumbnailStatus icon="locked" label="Unavailable" />;
  } else if (status === "READY" && thumbnailUrl) {
    const src = listThumbnailUrl(thumbnailUrl);
    content = <ThumbnailImage key={src} src={src} />;
  } else {
    content = <ThumbnailStatus icon="video" label="No thumbnail" />;
  }

  return (
    <div className="aspect-video w-20 shrink-0 overflow-hidden rounded-(--radius-lg) bg-(--secondary) text-(--muted-foreground) sm:w-24 @[36rem]:mr-3.5">
      {content}
    </div>
  );
}
