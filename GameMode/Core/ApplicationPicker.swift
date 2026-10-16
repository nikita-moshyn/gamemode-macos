//
//  ApplicationPicker.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import Foundation

/// Validation shared by the manual entry UI and its tests.
enum ApplicationPickerValidation {
    static func problem(for bundleID: String, existingIDs: Set<String>) -> String? {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an application bundle identifier." }
        guard trimmed.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*(?:\\.\\*)?$", options: .regularExpression) != nil else {
            return "Use letters, numbers, hyphens, and periods, with an optional .* suffix to match a group of applications."
        }
        guard !existingIDs.contains(trimmed) else { return "This application has already been added." }
        return nil
    }
}

@Reducer
struct ApplicationPicker {
    @ObservableState
    struct State: Equatable {
        var manualBundleID = ""
        var existingIDs: Set<String> = []
        var runningApps: [ApplicationCandidate] = []
        var feedback: String?
        var isBrowsing = false

        var validationMessage: String? {
            ApplicationPickerValidation.problem(for: manualBundleID, existingIDs: existingIDs)
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case runningApplicationsRequested
        case runningApplicationsLoaded([ApplicationCandidate])
        case browseButtonTapped
        case browseFinished(Result<ApplicationCandidate?, Error>)
        case addButtonTapped(ApplicationCandidate)
        case manualAddButtonTapped
        case doneButtonTapped
        case delegate(Delegate)

        enum Delegate {
            case addApplication(ApplicationCandidate, clearManualEntry: Bool)
        }
    }

    @Dependency(\.settingsViewClient) var client
    @Dependency(\.dismiss) var dismiss

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate:
                return .none
            case .runningApplicationsRequested:
                return .run { send in await send(.runningApplicationsLoaded(client.runningApplications())) }
            case .runningApplicationsLoaded(let apps):
                state.runningApps = apps
                return .none
            case .browseButtonTapped:
                guard !state.isBrowsing else { return .none }
                state.isBrowsing = true
                return .run { send in
                    let result = await Result { try await client.browseApplication() }
                    guard !Task.isCancelled else { return }
                    await send(.browseFinished(result))
                }
            case .browseFinished(let result):
                state.isBrowsing = false
                switch result {
                case .success(let app?): return .send(.delegate(.addApplication(app, clearManualEntry: false)))
                case .success(nil): return .none
                case .failure(let error): state.feedback = error.localizedDescription; return .none
                }
            case .addButtonTapped(let app):
                return .send(.delegate(.addApplication(app, clearManualEntry: false)))
            case .manualAddButtonTapped:
                guard state.validationMessage == nil else { return .none }
                let bundleID = state.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                return .send(.delegate(.addApplication(.init(bundleID: bundleID, name: bundleID), clearManualEntry: true)))
            case .doneButtonTapped:
                return .run { _ in await dismiss() }
            }
        }
    }
}

