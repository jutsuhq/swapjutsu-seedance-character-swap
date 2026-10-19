import Foundation

/// Settings › Agents as the person saved it. `UserDefaults.bool` and `double` also read the argument domain, and
/// anything that can launch the app (`open -b … --args -allowAgents YES`, as the swapjutsu binary does to start it)
/// could then turn agents on or give them a budget by itself; so a bundled app reads its persistent domain alone. The
/// unbundled `swift run` executable is a developer's own build, where launch arguments are the quick way to try agents.
struct AgentPreferences {
    static let allowKey = "allowAgents"
    static let budgetKey = "agentDailyBudget"
    /// The most, in USD, a money value from an agent or Settings may say: a render's `maxCost`, the daily budget.
    static let maxDollars = 10_000.0

    var defaults: UserDefaults = .standard
    /// The app's own defaults domain, its bundle ID; nil only for the unbundled executable.
    var domain: String? = Bundle.main.bundleIdentifier

    var isAllowed: Bool {
        guard let domain else { return defaults.bool(forKey: Self.allowKey) }
        return defaults.persistentDomain(forName: domain)?[Self.allowKey] as? Bool ?? false
    }

    /// USD a day that agents' renders may take, by the upper bound of their estimates. $0 until the person sets it:
    /// agents can quote but not spend.
    var dailyBudget: Double {
        let budget =
            if let domain {
                (defaults.persistentDomain(forName: domain)?[Self.budgetKey] as? NSNumber)?.doubleValue ?? 0
            } else {
                defaults.double(forKey: Self.budgetKey)
            }
        return Self.budget(budget)
    }

    /// A budget as the guard reads it: $0 to `maxDollars`, and $0 for a value that isn't a number.
    static func budget(_ dollars: Double) -> Double {
        dollars.isFinite ? min(max(0, dollars), maxDollars) : 0
    }
}
