import CCTransCore
import Foundation
import Testing

@Test func hidesInstallLocationForApplicationsBundle() {
    let bundleURL = URL(fileURLWithPath: "/Applications/CCTrans.app", isDirectory: true)

    #expect(AppInstallLocationNotice.menuTitle(forBundleURL: bundleURL) == nil)
}

@Test func showsInstallLocationForDevelopmentBundle() {
    let bundleURL = URL(
        fileURLWithPath: "/Users/kargnas/projects/cctrans/dist/CCTrans.app",
        isDirectory: true
    )

    #expect(AppInstallLocationNotice.menuTitle(forBundleURL: bundleURL) ==
        "Running from: /Users/kargnas/projects/cctrans/dist/CCTrans.app")
}

@Test func showsInstallLocationForUserApplicationsBundle() {
    let bundleURL = URL(fileURLWithPath: "/Users/kargnas/Applications/CCTrans.app", isDirectory: true)

    #expect(AppInstallLocationNotice.menuTitle(forBundleURL: bundleURL) ==
        "Running from: /Users/kargnas/Applications/CCTrans.app")
}
