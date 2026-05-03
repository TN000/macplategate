import Foundation
import AppKit

/// Explicit entrypoint — replaces `@main` na `SPZApp` struct.
///
/// Důvod: CLI mode (`replay-snapshots` headless replay) nesmí nikdy
/// inicializovat `AppState`, SwiftUI scene, WebServer ani připojení kamer.
/// Když je `@main` na App struct, AppState() se instancuje při app launch
/// before main runs — což trvá ~sekund + reservuje porty.
///
/// `Entrypoint.main()` se vykoná před vším ostatním → můžeme dispatch na
/// CLI a `exit(0)` aniž by SwiftUI vůbec startovalo. Pokud argv neodpovídá
/// CLI command, voláme `SPZApp.main()` (běžná GUI cesta).
///
/// Critical regression check: build .app bundle (`bash scripts/build_app.sh`)
/// + `open /Applications/SPZ.app` musí dál spustit GUI normálně.
///
/// Pozn.: Package.swift má `-parse-as-library` flag → soubor `main.swift`
/// nesmí mít top-level statements, jen `@main` struct s `main()` funkcí.
@main
struct Entrypoint {
    static func main() {
        let argv = CommandLine.arguments

        if argv.count >= 2, ReplayCLI.canHandle(argv) {
            ReplayCLI.run(args: Array(argv.dropFirst()))
            exit(0)
        }

        // GUI path — equivalent původního `@main` na `SPZApp`.
        SPZApp.main()
    }
}
