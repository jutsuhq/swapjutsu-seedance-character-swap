import Foundation
import SwapjutsuApp

#if MLX
    import SwapjutsuMLX
#endif

// The app lives in the SwapjutsuApp library; this executable only starts it, for `swift build` and `swift run`, and
// gives it the MLX implementation of the local vision models, which only the executable links. Started with
// `--vision-worker`, the same executable is the child process those models run in.
#if MLX
    if await MLXVisionBackend.serveIfWorker() { exit(0) }
    SwapjutsuApp.localVisionBackend = MLXVisionBackend(worker: Bundle.main.executableURL)
#endif
SwapjutsuApp.main()
