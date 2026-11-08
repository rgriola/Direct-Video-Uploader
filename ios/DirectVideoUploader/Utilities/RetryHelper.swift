import Foundation

/// Generic async retry with linear backoff.
/// Usage: `let result = try await withRetry { attempt in ... }`
@MainActor
func withRetry<T>(
    attempts: Int = 3,
    delay: Duration = .seconds(1),
    operation: @MainActor (Int) async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...attempts {
        do {
            return try await operation(attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
            if attempt < attempts {
                try? await Task.sleep(for: delay * attempt)
            }
        }
    }
    throw lastError!
}
