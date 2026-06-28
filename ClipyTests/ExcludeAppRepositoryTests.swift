//
//  ExcludeAppRepositoryTests.swift
//  ClipyTests
//

import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct ExcludeAppRepositoryTests {

    @Test func addsContainsAndOrders() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ExcludeAppRepository()
            try repo.add(bundleIdentifier: "com.example.b", name: "B")
            try repo.add(bundleIdentifier: "com.example.a", name: "A")

            #expect(try repo.contains(bundleIdentifier: "com.example.a"))
            #expect(try repo.contains(bundleIdentifier: "com.example.missing") == false)
            #expect(try repo.all().map(\.bundleIdentifier) == ["com.example.a", "com.example.b"])
        }
    }

    @Test func addSameBundleUpdatesNameWithoutDuplicating() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ExcludeAppRepository()
            try repo.add(bundleIdentifier: "com.example.a", name: "Old")
            try repo.add(bundleIdentifier: "com.example.a", name: "New")

            let all = try repo.all()
            #expect(all.count == 1)
            #expect(all.first?.name == "New")
        }
    }

    @Test func removes() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ExcludeAppRepository()
            try repo.add(bundleIdentifier: "com.example.a", name: "A")
            try repo.remove(bundleIdentifier: "com.example.a")
            #expect(try repo.all().isEmpty)
        }
    }
}
