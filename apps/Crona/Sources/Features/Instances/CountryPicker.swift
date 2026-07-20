import SwiftUI

// Prefijos telefónicos ITU por región ISO-3166. Nombres localizados vía Locale (es).
private let dialCodes: [String: String] = {
    let raw = """
    AF:93,AL:355,DZ:213,AD:376,AO:244,AG:1268,AR:54,AM:374,AU:61,AT:43,AZ:994,BS:1242,BH:973,BD:880,BB:1246,\
    BY:375,BE:32,BZ:501,BJ:229,BT:975,BO:591,BA:387,BW:267,BR:55,BN:673,BG:359,BF:226,BI:257,KH:855,CM:237,\
    CA:1,CV:238,CF:236,TD:235,CL:56,CN:86,CO:57,KM:269,CG:242,CD:243,CR:506,CI:225,HR:385,CU:53,CY:357,CZ:420,\
    DK:45,DJ:253,DM:1767,DO:1809,EC:593,EG:20,SV:503,GQ:240,ER:291,EE:372,SZ:268,ET:251,FJ:679,FI:358,FR:33,\
    GA:241,GM:220,GE:995,DE:49,GH:233,GR:30,GD:1473,GT:502,GN:224,GW:245,GY:592,HT:509,HN:504,HK:852,HU:36,\
    IS:354,IN:91,ID:62,IR:98,IQ:964,IE:353,IL:972,IT:39,JM:1876,JP:81,JO:962,KZ:7,KE:254,KI:686,KW:965,KG:996,\
    LA:856,LV:371,LB:961,LS:266,LR:231,LY:218,LI:423,LT:370,LU:352,MO:853,MG:261,MW:265,MY:60,MV:960,ML:223,\
    MT:356,MH:692,MR:222,MU:230,MX:52,FM:691,MD:373,MC:377,MN:976,ME:382,MA:212,MZ:258,MM:95,NA:264,NR:674,\
    NP:977,NL:31,NZ:64,NI:505,NE:227,NG:234,KP:850,MK:389,NO:47,OM:968,PK:92,PW:680,PA:507,PG:675,PY:595,PE:51,\
    PH:63,PL:48,PT:351,PR:1787,QA:974,RO:40,RU:7,RW:250,KN:1869,LC:1758,VC:1784,WS:685,SM:378,ST:239,SA:966,\
    SN:221,RS:381,SC:248,SL:232,SG:65,SK:421,SI:386,SB:677,SO:252,ZA:27,KR:82,SS:211,ES:34,LK:94,SD:249,SR:597,\
    SE:46,CH:41,SY:963,TW:886,TJ:992,TZ:255,TH:66,TL:670,TG:228,TO:676,TT:1868,TN:216,TR:90,TM:993,TV:688,\
    UG:256,UA:380,AE:971,GB:44,US:1,UY:598,UZ:998,VU:678,VE:58,VN:84,YE:967,ZM:260,ZW:263
    """
    var map: [String: String] = [:]
    for pair in raw.replacingOccurrences(of: "\n", with: "").split(separator: ",") {
        let parts = pair.split(separator: ":")
        if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
    }
    return map
}()

private func flagEmoji(_ region: String) -> String {
    region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value).map(String.init) }.joined()
}

struct CountryCode: Identifiable, Hashable {
    let region: String
    let flag: String
    let name: String
    let code: String
    var id: String { region }
}

let allCountries: [CountryCode] = {
    let locale = Locale(identifier: "es")
    return dialCodes.compactMap { region, code in
        guard let name = locale.localizedString(forRegionCode: region) else { return nil }
        return CountryCode(region: region, flag: flagEmoji(region), name: name, code: code)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}()

let favoriteRegions = ["EC", "AR", "BR", "CL", "CO", "MX", "PE", "UY", "US", "ES"]

func countryFor(_ region: String) -> CountryCode {
    allCountries.first { $0.region == region } ?? allCountries[0]
}

/// Selector de país estilo hoja: buscador + destacados + lista A-Z completa.
struct CountryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: CountryCode

    @State private var search = ""
    @State private var picked: CountryCode?

    private var filtered: [CountryCode] {
        search.isEmpty
            ? allCountries
            : allCountries.filter {
                $0.name.localizedCaseInsensitiveContains(search) || $0.code.contains(search.filter(\.isNumber))
            }
    }

    private var favorites: [CountryCode] {
        favoriteRegions.map(countryFor).filter { c in filtered.contains(c) }
    }

    private var grouped: [(letter: String, items: [CountryCode])] {
        Dictionary(grouping: filtered) { String($0.name.prefix(1)).uppercased() }
            .map { (letter: $0.key, items: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if search.isEmpty && !favorites.isEmpty {
                        Section {
                            ForEach(favorites) { row($0) }
                        }
                    }
                    ForEach(grouped, id: \.letter) { group in
                        Section(group.letter) {
                            ForEach(group.items) { row($0) }
                        }
                    }
                }
                .listStyle(.plain)

                Button {
                    if let picked { selection = picked }
                    dismiss()
                } label: {
                    Text("Confirmar selección")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(picked == nil)
                .opacity(picked == nil ? 0.5 : 1)
                .padding(16)
            }
            .navigationTitle("Selecciona tu país")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $search, prompt: "Buscar país")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func row(_ c: CountryCode) -> some View {
        Button {
            picked = c
        } label: {
            HStack {
                Text("\(c.flag)  \(c.name) (+\(c.code))")
                Spacer()
                if picked?.region == c.region {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
