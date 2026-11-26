import ClaudeStatusCore
import Foundation

// Claude Code lifecycle hook. Fails open: always exits 0 and never writes to stdout or
// stderr, so it cannot block a prompt, change a permission decision, or keep Claude running.
HookRunner.main()
exit(0)
