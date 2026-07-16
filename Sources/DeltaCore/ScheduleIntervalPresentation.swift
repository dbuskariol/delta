public enum ScheduleIntervalPresentation {
    public static func title(minutes: Int) -> String {
        let normalizedMinutes = max(1, minutes)
        if normalizedMinutes == 1 {
            return "Every minute"
        }
        return "Every \(normalizedMinutes) minutes"
    }
}
