import Darwin
import XCTest
@testable import ClaudeStatusCore

/// Fixture resembling a real user settings file: permissions, unrelated keys, and existing
/// hooks including a caffeinate-based sleep-prevention hook and a notifier on several events.
let existingHooksFixture = """
{
  "permissions": {
    "allow": [
      "Bash(git status:*)"
    ],
    "defaultMode": "auto"
  },
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/notify-when-attention-needed"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/pkill -u \\"$USER\\" -f 'caffeinate -i -t 3600' || true",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/caffeinate -i -t 3600 </dev/null >/dev/null 2>&1 &",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/audit-bash"
          }
        ]
      }
    ]
  },
  "modelSettings": {
    "ratio": 1.50,
    "big": 12345678901234567890,
    "exp": 1e-7
  },
  "theme": "dark",
  "unicode": "Grüße — 日本語 \\u001b",
  "enabledPlugins": {}
}

"""

final class HookConfiguratorTests: TempDirTestCase {
    let hookPath = "/Users/me/Library/Application Support/ClaudeStatus/bin/claude-status-hook"

    func configurator(_ settings: URL) -> HookConfigurator {
        HookConfigurator(settingsURL: settings, hookCommandPath: hookPath, backupsDir: tmp.appendingPathComponent("backups"))
    }

    func read(_ u: URL) -> String { String(decoding: try! Data(contentsOf: u), as: UTF8.self) }

    func parsed(_ u: URL) -> JSONValue { try! OrderedJSONParser.parse(try! Data(contentsOf: u)) }

    // MARK: install

    func testInstallIntoMissingFile() throws {
        let s = tmp.appendingPathComponent("sub/settings.json")
        let c = configurator(s)
        XCTAssertEqual(c.status().kind, .settingsMissing)
        let r = try c.install()
        XCTAssertTrue(r.changed)
        XCTAssertNil(r.backupPath, "no original file to back up")
        XCTAssertEqual(r.addedEvents.count, HookEventName.registered.count)
        XCTAssertTrue(c.status().isHealthy)
        var st = stat()
        XCTAssertEqual(stat(s.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testInstallIntoEmptyObjectAndEmptyFile() throws {
        for content in ["{}\n", "", "   \n"] {
            let s = write(content, to: "settings-\(UUID().uuidString).json")
            let c = configurator(s)
            XCTAssertTrue(try c.install().changed)
            XCTAssertTrue(c.status().isHealthy)
        }
    }

    func testInstallWithUnrelatedSettingsPreservesThem() throws {
        let s = write("{\n  \"theme\": \"light\",\n  \"env\": {\n    \"FOO\": \"bar\"\n  }\n}\n", to: "settings.json")
        let before = parsed(s)
        try configurator(s).install()
        let after = parsed(s)
        XCTAssertEqual(HookConfigurator.strip(after).0, before)
        XCTAssertEqual(after["theme"], .string("light"))
        XCTAssertEqual(after.objectValue?.map(\.0), ["theme", "env", "hooks"], "key order preserved, hooks appended")
    }

    func testInstallPreservesExistingHooksExactly() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let original = parsed(s)
        let originalText = read(s)
        let c = configurator(s)
        let r = try c.install()
        XCTAssertTrue(r.changed)
        let after = parsed(s)
        // Semantic preservation: removing our handlers gives back the original exactly.
        XCTAssertEqual(HookConfigurator.strip(after).0, original)
        // Existing handlers still present, in their original position (index 0) and unchanged.
        for event in ["Notification", "Stop", "UserPromptSubmit", "PreToolUse"] {
            let groups = after["hooks"]?[event]?.arrayValue ?? []
            XCTAssertEqual(groups.first, original["hooks"]?[event]?.arrayValue?.first, event)
            XCTAssertEqual(groups.count, 2, event)
            XCTAssertTrue(HookConfigurator.isOurs(groups[1]["hooks"]!.arrayValue![0]), event)
        }
        // Sleep-prevention hook text preserved byte-for-byte.
        XCTAssertTrue(read(s).contains("/usr/bin/caffeinate -i -t 3600 </dev/null >/dev/null 2>&1 &"))
        // Numbers keep their original text.
        XCTAssertTrue(read(s).contains("\"ratio\": 1.50"))
        XCTAssertTrue(read(s).contains("12345678901234567890"))
        XCTAssertTrue(read(s).contains("1e-7"))
        // Backup holds the original bytes with user-only permissions.
        let backup = try XCTUnwrap(r.backupPath)
        XCTAssertEqual(read(URL(fileURLWithPath: backup)), originalText)
        var st = stat()
        XCTAssertEqual(stat(backup, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // The registered handler conforms to the documented schema.
        let ours = after["hooks"]!["Stop"]!.arrayValue![1]
        XCTAssertNil(ours["matcher"])
        let h = ours["hooks"]!.arrayValue![0]
        XCTAssertEqual(h["type"], .string("command"))
        XCTAssertEqual(h["command"], .string("\"\(hookPath)\""))
        XCTAssertEqual(h["timeout"], .number("5"))
    }

    func testRepeatedInstallIsIdempotent() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let c = configurator(s)
        try c.install()
        let once = read(s)
        let r2 = try c.install()
        XCTAssertFalse(r2.changed)
        XCTAssertNil(r2.backupPath)
        XCTAssertEqual(read(s), once, "byte-identical, no rewrite")
        XCTAssertTrue(c.status().duplicateEvents.isEmpty)
    }

    func testDuplicateRegistrationsAreCollapsed() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let c = configurator(s)
        try c.install()
        // Simulate a manual copy-paste duplicate inside another group.
        var text = read(s)
        text = text.replacingOccurrences(of: "\"/usr/local/bin/notify-when-attention-needed\"\n", with: "\"/usr/local/bin/notify-when-attention-needed\"\n          },\n          {\n            \"type\": \"command\",\n            \"command\": \"\\\"\(hookPath)\\\"\"\n")
        try Data(text.utf8).write(to: s)
        XCTAssertEqual(c.status().duplicateEvents, ["Notification"])
        let r = try c.install()
        XCTAssertTrue(r.changed)
        XCTAssertTrue(c.status().isHealthy)
        // The user's notifier in that mixed group survived.
        XCTAssertEqual(parsed(s)["hooks"]?["Notification"]?.arrayValue?.first?["hooks"]?.arrayValue?.count, 1)
        XCTAssertEqual(HookConfigurator.strip(parsed(s)).0, HookConfigurator.strip(try OrderedJSONParser.parse(Data(existingHooksFixture.utf8))).0)
    }

    func testMovedHookPathIsRepaired() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        var old = configurator(s)
        old = HookConfigurator(settingsURL: s, hookCommandPath: "/old/place/claude-status-hook", backupsDir: tmp.appendingPathComponent("backups"))
        try old.install()
        let c = configurator(s)
        XCTAssertTrue(c.status().mismatchedCommand)
        try c.install()
        XCTAssertTrue(c.status().isHealthy)
        XCTAssertFalse(read(s).contains("/old/place"))
    }

    func testPartialInstallDetectedAndCompleted() throws {
        let s = write("{}", to: "settings.json")
        var c = configurator(s)
        c.events = ["Stop"]
        try c.install()
        let full = configurator(s)
        XCTAssertEqual(full.status().kind, .partial)
        try full.install()
        XCTAssertTrue(full.status().isHealthy)
    }

    // MARK: uninstall

    func testSelectiveUninstallRestoresOriginalExactly() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let originalText = read(s)
        let c = configurator(s)
        try c.install()
        let u = try c.uninstall()
        XCTAssertTrue(u.changed)
        XCTAssertEqual(u.removedHooks, HookEventName.registered.count)
        XCTAssertEqual(read(s), originalText, "install + uninstall is byte-identical for JSON.stringify-formatted input")
        XCTAssertEqual(c.status().kind, .notInstalled)
        XCTAssertFalse(try c.uninstall().changed)
    }

    func testUninstallPreservesLaterChanges() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let c = configurator(s)
        try c.install()
        // The user (or Claude Code) changes settings after installation.
        var v = parsed(s)
        if case .object(var top) = v { top.append(("newSetting", .bool(true))); v = .object(top) }
        try Data((OrderedJSONWriter.write(v) + "\n").utf8).write(to: s)
        try c.uninstall()
        let after = parsed(s)
        XCTAssertEqual(after["newSetting"], .bool(true))
        XCTAssertEqual(c.status().kind, .notInstalled)
    }

    func testUninstallKeepsUserHandlersInMixedGroups() throws {
        let mixed = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-thing"},{"type":"command","command":"\\"\(hookPath)\\""}]}]}}
        """
        let s = write(mixed, to: "settings.json")
        try configurator(s).uninstall()
        let groups = parsed(s)["hooks"]?["Stop"]?.arrayValue
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?.first?["hooks"]?.arrayValue?.first?["command"], .string("user-thing"))
    }

    func testUninstallRemovesHooksKeyOnlyIfWeCreatedIt() throws {
        let s = write("{\n  \"theme\": \"dark\"\n}\n", to: "settings.json")
        let c = configurator(s)
        try c.install()
        try c.uninstall()
        XCTAssertEqual(read(s), "{\n  \"theme\": \"dark\"\n}\n")
        let s2 = write("{\n  \"hooks\": {}\n}\n", to: "settings2.json")
        let c2 = configurator(s2)
        try c2.install()
        try c2.uninstall()
        XCTAssertEqual(parsed(s2), .object([]), "an emptied hooks object we touched is removed")
    }

    // MARK: failure handling

    func testInvalidJSONIsRefusedAndUntouched() throws {
        for bad in ["{\"a\": }", "{\"hooks\": []}", "[1]", "{\"hooks\": {\"Stop\": {}}}", "{\"a\":1} trailing", "{\"s\":\"\\ud800\"}"] {
            let s = write(bad, to: "settings-\(UUID().uuidString).json")
            XCTAssertThrowsError(try configurator(s).install(), bad)
            XCTAssertEqual(read(s), bad, "file unchanged")
            XCTAssertThrowsError(try configurator(s).uninstall(), bad)
            XCTAssertEqual(configurator(s).status().kind, .invalidSettings)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("backups").path), "no backups for refused edits")
    }

    func testConcurrentModificationIsDetected() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        var c = configurator(s)
        let concurrent = existingHooksFixture.replacingOccurrences(of: "\"theme\": \"dark\"", with: "\"theme\": \"light\"")
        c.beforeCommit = { try! Data(concurrent.utf8).write(to: s) }
        XCTAssertThrowsError(try c.install()) { XCTAssertEqual($0 as? ConfigError, .concurrentModification) }
        XCTAssertEqual(read(s), concurrent, "the concurrent writer's content is not overwritten")
        // A retry without interference succeeds and keeps the concurrent change.
        c.beforeCommit = nil
        try c.install()
        XCTAssertEqual(parsed(s)["theme"], .string("light"))
    }

    func testDryRunWritesNothing() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let r = try configurator(s).install(dryRun: true)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(read(s), existingHooksFixture)
    }

    func testSymlinkedSettingsFileIsEditedInPlace() throws {
        let real = write(existingHooksFixture, to: "dotfiles-settings.json")
        let link = tmp.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try configurator(link).install()
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "symlink preserved")
        XCTAssertTrue(configurator(real).status().isHealthy)
    }

    func testBackupAndRollbackRoundTrip() throws {
        let s = write(existingHooksFixture, to: "settings.json")
        let c = configurator(s)
        let r = try c.install()
        let backup = URL(fileURLWithPath: try XCTUnwrap(r.backupPath))
        // verify-preserved logic: everything except our hooks matches the backup.
        XCTAssertEqual(HookConfigurator.strip(parsed(s)).0, HookConfigurator.strip(parsed(backup)).0)
        // Rollback by selective uninstall returns exactly the backup bytes.
        try c.uninstall()
        XCTAssertEqual(read(s), read(backup))
    }
}

final class OrderedJSONTests: XCTestCase {
    func testRoundTripIsByteExactForStringifyFormat() throws {
        let text = existingHooksFixture.trimmingCharacters(in: .newlines)
        let v = try OrderedJSONParser.parse(Data(text.utf8))
        XCTAssertEqual(OrderedJSONWriter.write(v), text)
    }

    func testEscapes() throws {
        let v = try OrderedJSONParser.parse(Data(#"{"a":"q\"b\\s\/n\n\t\u0001\ud83d\ude00é"}"#.utf8))
        XCTAssertEqual(v["a"], .string("q\"b\\s/n\n\t\u{01}😀é"))
        XCTAssertEqual(OrderedJSONWriter.write(v), "{\n  \"a\": \"q\\\"b\\\\s/n\\n\\t\\u0001😀é\"\n}")
    }

    func testRejectsInvalid() {
        for bad in ["", "{", "{\"a\":1,}", "[1,]", "01", "1.", "-", "tru", "\"\u{01}\"", "{\"a\" 1}", "nul"] {
            XCTAssertThrowsError(try OrderedJSONParser.parse(Data(bad.utf8)), bad)
        }
        let deep = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        XCTAssertThrowsError(try OrderedJSONParser.parse(Data(deep.utf8))) { XCTAssertEqual($0 as? JSONParseError, .tooDeep) }
    }

    func testOrderAndDuplicatesPreserved() throws {
        let v = try OrderedJSONParser.parse(Data(#"{"z":1,"a":2,"z":3}"#.utf8))
        XCTAssertEqual(v.objectValue?.map(\.0), ["z", "a", "z"])
        XCTAssertEqual(v["z"], .number("3"))
    }
}
