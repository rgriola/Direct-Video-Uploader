export default async function uploadCapabilityRoutes(fastify, { originalUploads }) {
    if (typeof originalUploads !== 'boolean') {
        throw new TypeError('Upload capabilities require an original-upload setting');
    }
    fastify.get('/api/upload-capabilities', {
        preHandler: [fastify.authenticate],
    }, async (_request, reply) => {
        reply.header('Cache-Control', 'no-store');
        return { originalUploads };
    });
}
