import ProjectDescription

let projectName = "SerialManager"
let bundlePrefix = "it.stefer"

let baseSettings: SettingsDictionary = [
    "DEVELOPMENT_TEAM": "T7H24G7BFW",
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_VERSION": "6.0",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
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
            infoPlist: .extendingDefault(with: [
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "\(bundlePrefix).\(projectName).backup",
                        "UTTypeDescription": "SerialManager Backup",
                        "UTTypeConformsTo": ["public.data"],
                        "UTTypeTagSpecification": [
                            "public.filename-extension": ["smbackup"],
                        ],
                    ],
                ],
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            // Data protection keychain (docs/adr/0002-keychain-implementation.md): a real
            // development signature and the app's own keychain access group, authorized by a
            // provisioning profile. CI builds with signing disabled.
            entitlements: .dictionary([
                "keychain-access-groups": ["$(AppIdentifierPrefix)\(bundlePrefix).\(projectName)"],
            ]),
            dependencies: [],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "Apple Development",
            ])
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
