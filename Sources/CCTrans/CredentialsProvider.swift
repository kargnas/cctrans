import CCTransCore
import Foundation

struct CredentialsProvider {
    func credentials() -> TranslatorCredentials {
        #if MAS_BUILD
        let paths = [SharedAppStorage.fileURL("credentials.env")]
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundleURL = Bundle.main.bundleURL
        // `open CCTrans.app` does not preserve the project root as cwd, so dev builds also
        // check paths around the app bundle before falling back to the user config file.
        let paths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env.local"),
            bundleURL.deletingLastPathComponent().appendingPathComponent(".env.local"),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env.local"),
            home.appendingPathComponent(".config/cctrans/.env"),
        ]
        #endif
        let environment = EnvLoader.mergedEnvironment(dotenv: EnvLoader.load(paths: paths))
        return TranslatorCredentials(
            openRouterAPIKey: environment["OPENROUTER_API_KEY"],
            huggingFaceToken: environment["HF_TOKEN"],
            // Managed-provider dev bypass (QA only). Put `CCTRANS_DEV_TOKEN=cctdev_…`
            // in ~/.config/cctrans/.env for direct builds, or pass it via the
            // environment for local MAS QA. Signed builds leave it unset and fall
            // back to platform store identity. Never commit this value.
            cctransDevToken: environment["CCTRANS_DEV_TOKEN"]
        )
    }
}
