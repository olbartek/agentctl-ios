# The contract

[`CONTRACT.md`](../../CONTRACT.md) specifies the engine independently of Swift: the script language and its quoting,
command resolution, the runtime commands, the exact step output format, `expect` semantics and failure text, the exit
codes, the determinism requirements, and the in-app bridge's wire protocol. It is what a port in another language
implements, and it is a more precise description of the behaviour the other guides summarize. Its examples are
TinyApp's, and their output is real: it is what this package prints.

CONTRACT.md lives in this repository. A change to it lands here first and is copied to
[agentctl-android](https://github.com/olbartek/agentctl-android) unchanged, and it is always a minor release of both
libraries: the two implement the same version of it, so 0.X.y here and 0.X.z there drive the same scripts to the same
bytes.

Where the contract leaves a choice open, its [open questions](../../CONTRACT.md#open-questions) list it, and this package's
behaviour is the reference both ports follow until the question is settled.
