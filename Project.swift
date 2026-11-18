import ProjectDescription

let projectName = "SerialManager"
let bundlePrefix = "it.stefer"

let baseSettings: SettingsDictionary = [
    "DEVELOPMENT_TEAM": "T7H24G7BFW",
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_VERSION": "6.0",
]

let project = Project(
    name: projectName,
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: projectName,
            destinations: .macOS,
            product: .app,
            bundleId: "\(bundlePrefix).\(projectName)",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [:]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: []
        ),
        .target(
            name: "\(projectName)Tests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundlePrefix).\(projectName)Tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: projectName)]
        ),
    ]
)
