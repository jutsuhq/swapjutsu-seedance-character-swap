import SwiftUI

/// Whether AI agents on this Mac may drive the app through the `swapjutsu` binary, and how much they may spend a day.
struct AgentSettings: View {
    @AppStorage(AgentServer.allowKey) private var allowAgents = false
    @AppStorage(AgentPreferences.budgetKey) private var budget = 0.0
    @Environment(AgentServer.self) private var server
    @Environment(JobStore.self) private var jobs
    @FocusState private var isBudgetFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Agents",
                footer: "Agents such as Claude Code reach the app through a socket only programs running as you "
                    + "can open. They can't delete anything and never see your Comfy key. Turning this off refuses "
                    + "their next command; what they started keeps going."
            ) {
                SettingsRow(label: "Allow agents", detail: "Off until you turn it on", isFirst: true) {
                    Toggle("Allow agents", isOn: isAllowed).settingsSwitch()
                }
                SettingsRow(
                    label: "Socket",
                    detail: server.socket?.path(percentEncoded: false)
                        ?? "Needs a build signed with a team ID (DEVELOPMENT_TEAM)"
                ) {
                    Text(server.isListening ? "Listening" : "Closed")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                }
            }
            if let failure = server.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
            SettingsSection(
                title: "Spending",
                footer: "Agents can always ask what a render costs. They send one only when the top of its "
                    + "estimate fits both the limit they give it and what is left of today's budget, counting their "
                    + "renders on their way. Anything over waits in Jobs until you send it."
            ) {
                SettingsRow(label: "Daily agent budget", detail: "$0: agents can quote but not spend", isFirst: true) {
                    TextField("0.00", value: savedBudget, format: .currency(code: "USD"))
                        .focused($isBudgetFocused)
                        .themedField(isFocused: isBudgetFocused)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 120)
                }
                SettingsRow(label: "Taken by agents today", detail: "Each render by the top of its estimate") {
                    Text(SeedancePrice.dollars(jobs.agentSpent()))
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// Shows what the server goes by, the saved setting, rather than `allowAgents`, which also reads a launch
    /// argument the app ignores. Reading `allowAgents` keeps the switch redrawn when the setting changes.
    private var isAllowed: Binding<Bool> {
        Binding(
            get: {
                _ = allowAgents
                return server.isAllowed
            },
            set: { allowAgents = $0 })
    }

    /// The same for the budget: the saved value the guard reads, from $0 to `AgentPreferences.maxDollars`.
    private var savedBudget: Binding<Double> {
        Binding(
            get: {
                _ = budget
                return AgentPreferences().dailyBudget
            },
            set: { budget = AgentPreferences.budget($0) })
    }
}
