import { useAuth } from "@/auth/AuthProvider";
import { useMyAssets, useUploadCapabilities } from "@/hooks/use-dashboard";
import { AssetList } from "@/components/AssetList";
import { OriginalUploadPanel } from "@/components/OriginalUploadPanel";
import { submitAssetForm } from "@/lib/api";

export function UserDashboard() {
  const { user } = useAuth();
  const { data: assets, isLoading, isError, error, refetch } = useMyAssets(!!user);
  const { data: capabilities } = useUploadCapabilities(!!user);

  return (
    <section aria-labelledby="my-videos-title">
      <h2 id="my-videos-title" className="mb-2 text-(length:--text-2xl) font-bold">My Videos</h2>
      <p className="mb-6 text-(length:--text-sm) text-(--muted-foreground)">
        View your uploads and open available clips.
      </p>
      {capabilities?.originalUploads && <OriginalUploadPanel />}
      {isError && (
        <div role="alert" className="mb-4 text-(--accent-red)">
          <p>Could not load your videos: {error instanceof Error ? error.message : "Unknown error"}</p>
          <button type="button" className="underline" onClick={() => void refetch()}>Retry</button>
        </div>
      )}
      {(!isError || assets !== undefined) && (
        <AssetList
          assets={assets}
          isLoading={isLoading}
          viewerRole="USER"
          title="Your videos"
          emptyText="Your uploaded videos will appear here."
          onSubmitContext={async (assetId, values) => {
            await submitAssetForm(assetId, values);
            await refetch();
          }}
        />
      )}
    </section>
  );
}
