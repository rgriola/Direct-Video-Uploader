import path from 'node:path';

export class LocalMediaError extends Error {}

export function localUploadPath(storageUrl) {
    if (storageUrl == null) return null;
    if (typeof storageUrl !== 'string' || !storageUrl.startsWith('/uploads/')) {
        throw new LocalMediaError('Unrecognized local media URL requires manual review');
    }
    const root = path.resolve(process.cwd(), 'uploads');
    const relative = storageUrl.slice('/uploads/'.length);
    if (!relative || relative.includes('\\') || relative.startsWith('/')
        || path.posix.normalize(relative) !== relative) {
        throw new LocalMediaError('Local upload path is invalid');
    }
    const filePath = path.resolve(root, relative);
    if (!filePath.startsWith(`${root}${path.sep}`)) {
        throw new LocalMediaError('Local upload path is outside the uploads directory');
    }
    return filePath;
}

export async function removeLocalUpload(db, clip, fileSystem) {
    const filePath = localUploadPath(clip.storageUrl);
    if (!filePath) return;
    const root = path.resolve(process.cwd(), 'uploads');
    try {
        const canonicalRoot = await fileSystem.realpath(root);
        const canonicalFile = await fileSystem.realpath(filePath);
        if (canonicalFile !== path.join(canonicalRoot, path.relative(root, filePath))) {
            throw new LocalMediaError('Local upload path contains a symbolic link');
        }
        const shared = await db.clip.findFirst({
            where: { id: { not: clip.id }, storageUrl: clip.storageUrl },
            select: { id: true },
        });
        if (shared) {
            throw new LocalMediaError('Local media is shared by multiple clips and requires manual review');
        }
        await fileSystem.unlink(canonicalFile);
    } catch (err) {
        if (err.code !== 'ENOENT') throw err;
    }
}
