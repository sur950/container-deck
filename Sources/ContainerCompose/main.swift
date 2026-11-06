import Foundation
import DeckCore

// `container compose`: Apple's CLI runs this binary as a plugin from
// /usr/local/libexec/container-plugins/compose/bin/compose. argv[0] is the
// binary path, the rest is what came after `container compose`.
let code = await ComposeCLI().run(Array(CommandLine.arguments.dropFirst()))
exit(code)
