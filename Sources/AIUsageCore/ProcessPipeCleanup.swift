import Foundation

public enum ProcessPipeCleanup {
    public static func finish(process: Process?, input: Pipe?, output: Pipe?, error: Pipe?) {
        output?.fileHandleForReading.readabilityHandler = nil
        error?.fileHandleForReading.readabilityHandler = nil
        input?.fileHandleForWriting.closeFile()

        if process?.isRunning == true {
            process?.terminate()
            process?.waitUntilExit()
        }
    }
}
