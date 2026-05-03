import SwiftUI

/// SF Symbol mapping pro VehicleClassifier.Classification.type labels.
/// Použito v RecentRow (StreamView.swift) + kdekoli chceme zobrazit vehicle badge.
func vehicleSFSymbol(for type: String?) -> String {
    switch type?.lowercased() {
    case "car": return "car.fill"
    case "suv": return "car.side.fill"
    case "truck": return "truck.box.fill"
    case "van": return "bus.fill"
    case "bus": return "bus.doubledecker.fill"
    case "motorcycle": return "scooter"
    case "bicycle": return "bicycle"
    default: return "car"
    }
}

/// Color-name string (z VehicleClassifier palety) → SwiftUI Color. Použito pro
/// malou barevnou tečku v RecentRow badge.
func swiftUIColorForName(_ name: String) -> Color {
    switch name.lowercased() {
    case "black":  return Color(red: 0.10, green: 0.10, blue: 0.10)
    case "white":  return Color(red: 0.95, green: 0.95, blue: 0.95)
    case "gray":   return Color(red: 0.50, green: 0.50, blue: 0.50)
    case "silver": return Color(red: 0.75, green: 0.75, blue: 0.75)
    case "red":    return Color(red: 0.80, green: 0.15, blue: 0.15)
    case "blue":   return Color(red: 0.15, green: 0.25, blue: 0.80)
    case "green":  return Color(red: 0.15, green: 0.70, blue: 0.20)
    case "yellow": return Color(red: 0.95, green: 0.85, blue: 0.15)
    case "orange": return Color(red: 0.95, green: 0.55, blue: 0.15)
    case "brown":  return Color(red: 0.45, green: 0.30, blue: 0.15)
    default:       return Color.gray
    }
}
