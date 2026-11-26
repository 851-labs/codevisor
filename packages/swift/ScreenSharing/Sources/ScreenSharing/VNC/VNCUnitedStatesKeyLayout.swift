public enum VNCUnitedStatesKeyLayout {
  public static let shift: UInt32 = 0x02
  public static let capsLock: UInt32 = 0x04
  public static let option: UInt32 = 0x08

  public static let layout: VNCKeyTranslator.Layout = { code, carbonModifiers in
    guard let key = keys[code] else { return nil }

    let isShifted = carbonModifiers & shift != 0
    let isCapitalised = carbonModifiers & capsLock != 0 && key.plain.properties.isAlphabetic
    return isShifted || isCapitalised ? key.shifted : key.plain
  }

  private struct Key {
    let plain: Unicode.Scalar
    let shifted: Unicode.Scalar
  }

  private static let keys: [UInt16: Key] = {
    let rows: [(UInt16, Unicode.Scalar, Unicode.Scalar)] = [
      (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
      (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
      (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
      (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
      (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
      (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"),
      (43, ",", "<"), (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (49, " ", " "), (50, "`", "~"),
    ]
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, Key(plain: $0.1, shifted: $0.2)) })
  }()
}
