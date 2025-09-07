import SwiftUI
import FirebaseFirestore
import FirebaseStorage

// MARK: - Models
struct Member: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
}

struct Expense: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var note: String
    var amount: Double
    var paidBy: UUID // Member.id
    var splitWith: [UUID] // by default all members
}

struct Trip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var detail: String = ""
    var currency: Currency = .usd
    var createdAt: Date = Date()
    var members: [Member] = []
    var expenses: [Expense] = []

    var totalAmount: Double { expenses.reduce(0) { $0 + $1.amount } }
    var transactionsCount: Int { expenses.count }

    func totalPaidBy(member id: UUID) -> Double {
        expenses.filter { $0.paidBy == id }.reduce(0) { $0 + $1.amount }
    }

    func totalOwesFor(member id: UUID) -> Double {
        expenses.reduce(0) { acc, e in
            guard e.splitWith.contains(id) else { return acc }
            let share = e.amount / Double(max(e.splitWith.count, 1))
            return acc + share
        }
    }

    var balances: [(Member, Double)] {
        members.map { m in
            let paid = totalPaidBy(member: m.id)
            let owes = totalOwesFor(member: m.id)
            return (m, paid - owes)
        }
        .sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
    }
}

enum Currency: String, CaseIterable, Codable, Identifiable {
    case usd = "USD", eur = "EUR", gbp = "GBP", inr = "INR", aud = "AUD", cad = "CAD"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .inr: return "₹"
        case .aud: return "$"
        case .cad: return "$"
        }
    }
    
    var gradient: LinearGradient {
        switch self {
        case .usd: return LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .eur: return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gbp: return LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .inr: return LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aud: return LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cad: return LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Store (local JSON persistence)
final class TripStore: ObservableObject {
    @Published var trips: [Trip] = []
    private let firebase = FirebaseService()

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("TripExpenseData.json")
    }()

    init() {
        // Load local cache first for immediate UI
        load()
        // Then refresh from Firebase and cache it locally
        firebase.fetchTrips { [weak self] remoteTrips in
            guard let self else { return }
            DispatchQueue.main.async {
                if remoteTrips.isEmpty && self.trips.isEmpty {
                    // Seed one sample trip if nothing exists yet
                    let sample = Trip(
                        name: "SUSO",
                        detail: "Trip to Switzerland",
                        currency: .usd,
                        createdAt: Date(),
                        members: [Member(name: "Rajiv"), Member(name: "Vaidhi")],
                        expenses: []
                    )
                    self.trips = [sample]
                    self.save()
                    self.firebase.saveTrip(sample) { _ in }
                } else if !remoteTrips.isEmpty {
                    self.trips = remoteTrips
                    self.save()
                }
            }
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Trip].self, from: data) {
            trips = decoded
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(trips)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Save error: \(error)")
        }
    }

    // MARK: Mutations
    func addTrip(_ trip: Trip) {
        trips.insert(trip, at: 0)
        save()
        firebase.saveTrip(trip) { error in
            if let error { print("Firebase saveTrip error: \(error)") }
        }
    }

    func updateTrip(_ trip: Trip) {
        if let idx = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[idx] = trip
            save()
            firebase.updateTrip(trip) { error in
                if let error { print("Firebase updateTrip error: \(error)") }
            }
        }
    }

    func deleteTrips(at offsets: IndexSet) {
        let toDelete = offsets.map { trips[$0] }
        trips.remove(atOffsets: offsets)
        save()
        toDelete.forEach { trip in
            firebase.deleteTrip(trip.id) { error in
                if let error { print("Firebase deleteTrip error: \(error)") }
            }
        }
    }

    func addExpense(_ expense: Expense, to tripID: UUID) {
        guard let idx = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[idx].expenses.insert(expense, at: 0)
        save()
        firebase.saveExpense(expense, to: tripID) { error in
            if let error { print("Firebase saveExpense error: \(error)") }
        }
    }

    func updateExpense(_ expense: Expense, in tripID: UUID) {
        guard let tIdx = trips.firstIndex(where: { $0.id == tripID }) else { return }
        if let eIdx = trips[tIdx].expenses.firstIndex(where: { $0.id == expense.id }) {
            trips[tIdx].expenses[eIdx] = expense
            save()
            firebase.updateExpense(expense, in: tripID) { error in
                if let error { print("Firebase updateExpense error: \(error)") }
            }
        }
    }

    func deleteExpense(_ expenseID: UUID, in tripID: UUID) {
        guard let tIdx = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[tIdx].expenses.removeAll { $0.id == expenseID }
        save()
        firebase.deleteExpense(expenseID, in: tripID) { error in
            if let error { print("Firebase deleteExpense error: \(error)") }
        }
    }
}

// MARK: - Views
struct TripListView: View {
    @EnvironmentObject var store: TripStore
    @State private var showNewTrip = false
    @State private var editingTrip: Trip? = nil
    @State private var search = ""
    @State private var tripToCreate = Trip(name: "")
    // 🗑️ New: track which trip to delete
    @State private var tripToDelete: Trip? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient (light)
                LinearGradient(
                    colors: [Color.white, Color.cyan.opacity(0.4), Color.blue.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                List {
                    if store.trips.isEmpty {
                        VStack(spacing: 30) {
                            Spacer().frame(height: 100)
                            Image(systemName: "map.circle.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.cyan, .blue, .purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            VStack(spacing: 12) {
                                Text("Ready for Adventure?")
                                    .font(.title.bold())
                                    .foregroundColor(.black)
                                Text("Create your first trip to start tracking expenses")
                                    .font(.subheadline)
                                    .foregroundColor(.black.opacity(0.7))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredTrips) { trip in
                            NavigationLink(value: trip) {
                                TripCard(trip: trip)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    tripToDelete = trip
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editingTrip = trip }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    tripToDelete = trip
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .preferredColorScheme(.light)
            .toolbar {
                // 🔵 Gradient title
                ToolbarItem(placement: .principal) {
                    Text("TripExpense")
                        .font(.largeTitle.bold())
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        tripToCreate = Trip(name: "")
                        showNewTrip = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("New")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: boundTrip(trip))
            }
            // 🗑️ Deletion confirm dialog
            .confirmationDialog(
                "Delete this trip?",
                isPresented: Binding(
                    get: { tripToDelete != nil },
                    set: { if !$0 { tripToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let t = tripToDelete, let idx = store.trips.firstIndex(of: t) {
                        store.deleteTrips(at: IndexSet(integer: idx))
                    }
                    tripToDelete = nil
                }
                Button("Cancel", role: .cancel) { tripToDelete = nil }
            }
        }
        .searchable(text: $search, prompt: "Search trips...")
        .sheet(isPresented: $showNewTrip) { TripEditor(trip: $tripToCreate, isNew: true) }
        .sheet(item: $editingTrip) { t in TripEditor(trip: bindingForTrip(t), isNew: false) }
    }

    private var filteredTrips: [Trip] {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return store.trips }
        return store.trips.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }
    }

    private func boundTrip(_ trip: Trip) -> Binding<Trip> {
        guard let index = store.trips.firstIndex(where: { $0.id == trip.id }) else {
            fatalError("Cannot find trip in store.")
        }
        return $store.trips[index]
    }

    private func bindingForTrip(_ trip: Trip) -> Binding<Trip> {
        guard let index = store.trips.firstIndex(where: { $0.id == trip.id }) else {
            fatalError("Missing trip for sheet.")
        }
        return $store.trips[index]
    }
}

struct TripCard: View {
    var trip: Trip
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(trip.name)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    if !trip.detail.isEmpty {
                        Text(trip.detail)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                Spacer()
                
                Text(trip.currency.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(trip.currency.gradient)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .padding(.trailing, 4)
            }
            
            HStack(spacing: 20) {
                Label("\(trip.members.count)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                
                Label(trip.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Divider()
                .background(.white.opacity(0.2))
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Spent")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("\(trip.currency.symbol)\(trip.totalAmount, specifier: "%.2f")")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Transactions")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("\(trip.transactionsCount)")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.2, blue: 0.3),
                            Color(red: 0.15, green: 0.15, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.2), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        )
    }
}

// MARK: - Trip Editor
struct TripEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: TripStore
    @Binding var trip: Trip
    var isNew: Bool
    @State private var memberName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.white, Color.cyan.opacity(0.4), Color.blue.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SectionHeader(title: "Trip Information")
                        SectionCard {
                            VStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Trip Name")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    TextField("Enter trip name", text: $trip.name)
                                        .inputField()
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Description")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    TextField("Add a short description", text: $trip.detail, axis: .vertical)
                                        .lineLimit(3...6)
                                        .inputField()
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Currency")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Picker("Currency", selection: $trip.currency) {
                                            ForEach(Currency.allCases) { currency in
                                                Text("\(currency.rawValue) \(currency.symbol)").tag(currency)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        Spacer(minLength: 0)
                                    }
                                    .inputField()
                                }
                            }
                        }

                        SectionHeader(title: "Trip Members")
                        SectionCard {
                            VStack(spacing: 12) {
                                HStack(spacing: 10) {
                                    TextField("Enter person name", text: $memberName)
                                        .inputField()
                                    Button(action: addMember) {
                                        Image(systemName: "plus")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                            .frame(width: 36, height: 36)
                                            .background(
                                                LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            )
                                            .clipShape(Circle())
                                    }
                                    .disabled(memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }

                                if trip.members.isEmpty {
                                    Text("No members yet")
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(trip.members) { member in
                                            HStack(spacing: 12) {
                                                Image(systemName: "person.crop.circle.fill")
                                                    .foregroundColor(.cyan)
                                                Text(member.name)
                                                Spacer()
                                                Button(role: .destructive) {
                                                    trip.members.removeAll { $0.id == member.id }
                                                } label: {
                                                    Image(systemName: "trash")
                                                        .foregroundColor(.red)
                                                }
                                            }
                                            .padding(10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.white.opacity(0.9))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .stroke(.black.opacity(0.05), lineWidth: 1)
                                                    )
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(isNew ? "Create Trip" : "Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.light)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.primary.opacity(0.8))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { save() }
                        .disabled(trip.name.isEmpty || trip.members.isEmpty)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: trip.name.isEmpty || trip.members.isEmpty ?
                                    [.gray.opacity(0.3), .gray.opacity(0.5)] :
                                    [.cyan, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func addMember() {
        let clean = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        trip.members.append(Member(name: clean))
        memberName = ""
    }

    private func save() {
        if isNew { store.addTrip(trip) } else { store.updateTrip(trip) }
        dismiss()
    }
}

// MARK: - Modern Section + Input Styling
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.bold())
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.95, green: 0.97, blue: 1.0))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.black.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        )
    }
}

private struct InputBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.black.opacity(0.05), lineWidth: 1)
                    )
            )
    }
}

private extension View {
    func inputField() -> some View { self.modifier(InputBackground()) }
}

// MARK: - Expense Editor
struct ExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: TripStore
    @Binding var trip: Trip
    @State var expense: Expense

    init(trip: Binding<Trip>, expense: Expense) {
        self._trip = trip
        self._expense = State(initialValue: expense)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.white, Color.cyan.opacity(0.4), Color.blue.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                Form {
                    Section {
                        DatePicker("Date", selection: $expense.date, displayedComponents: .date)
                        TextField("Description", text: $expense.note)
                        TextField("Amount", value: $expense.amount, format: .number)
                            .keyboardType(.decimalPad)
                        Picker("Paid by", selection: $expense.paidBy) {
                            ForEach(trip.members) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                    } header: {
                        Text("Expense Details")
                            .foregroundColor(.primary.opacity(0.8))
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(red: 0.95, green: 0.97, blue: 1.0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.black.opacity(0.06), lineWidth: 1)
                            )
                    )
                    
                    Section {
                        ToggleMultiPicker(options: trip.members, selection: $expense.splitWith)
                    } header: {
                        Text("Split With")
                            .foregroundColor(.primary.opacity(0.8))
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(red: 0.95, green: 0.97, blue: 1.0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.black.opacity(0.06), lineWidth: 1)
                            )
                    )
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.light)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.primary.opacity(0.8))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if expense.splitWith.isEmpty {
                            expense.splitWith = trip.members.map { $0.id }
                        }
                        store.updateExpense(expense, in: trip.id)
                        dismiss()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Trip Detail & Expenses
struct TripDetailView: View {
    @EnvironmentObject var store: TripStore
    @Binding var trip: Trip
    @State private var newExpense = Expense(note: "", amount: 0, paidBy: UUID(), splitWith: [])
    @State private var editExpense: Expense? = nil
    @State private var amountInput: String = ""
    @State private var pendingDelete: Expense? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white, Color.cyan.opacity(0.4), Color.blue.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addExpenseCard
                    expenseList
                    summaryCard
                    balancesCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .sheet(item: $editExpense) { exp in
            ExpenseEditor(trip: $trip, expense: exp)
        }
        .onAppear {
            if !trip.members.contains(where: { $0.id == newExpense.paidBy }) {
                newExpense.paidBy = trip.members.first?.id ?? UUID()
            }
            if newExpense.splitWith.isEmpty {
                newExpense.splitWith = trip.members.map { $0.id }
            }
        }
        .confirmationDialog(
            "Delete this expense?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let exp = pendingDelete {
                    store.deleteExpense(exp.id, in: trip.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let exp = pendingDelete {
                Text("\"\(exp.note)\" · \(trip.currency.symbol)\(exp.amount, specifier: "%.2f") on \(exp.date.formatted(date: .abbreviated, time: .omitted))")
            }
        }
    }

    private var addExpenseCard: some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Add New Expense")
                    .font(.headline.bold())
                    .foregroundColor(.primary)
                Spacer()
            }
            
            VStack(spacing: 16) {
                TextField("What was this for?", text: $newExpense.note)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.8))
                            .stroke(.black.opacity(0.1), lineWidth: 1)
                    )

                DatePicker("Date", selection: $newExpense.date, displayedComponents: .date)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.8))
                            .stroke(.black.opacity(0.1), lineWidth: 1)
                    )

                HStack {
                    Text("Amount")
                        .foregroundColor(.primary.opacity(0.8))
                    Spacer()
                    HStack(spacing: 8) {
                        TextField("0.00", text: $amountInput)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text(trip.currency.symbol)
                            .foregroundColor(.primary.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.8))
                        .stroke(.black.opacity(0.1), lineWidth: 1)
                )

                HStack {
                    Text("Paid by")
                        .foregroundColor(.primary.opacity(0.8))
                    Spacer()
                    Menu {
                        Picker("Paid by", selection: $newExpense.paidBy) {
                            ForEach(trip.members) { m in Text(m.name).tag(m.id) }
                        }
                    } label: {
                        HStack {
                            Text(memberName(newExpense.paidBy))
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.8))
                        .stroke(.black.opacity(0.1), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Split with")
                        .foregroundColor(.primary.opacity(0.8))
                    ToggleMultiPicker(options: trip.members, selection: $newExpense.splitWith)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.8))
                        .stroke(.black.opacity(0.1), lineWidth: 1)
                )

                Button(action: addExpense) {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add Expense")
                    }
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: canAdd ? [.cyan, .blue] : [.gray.opacity(0.3), .gray.opacity(0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: canAdd ? .cyan.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
                }
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.2, blue: 0.3),
                            Color(red: 0.15, green: 0.15, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.2), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        )
    }

    private var expenseList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if trip.expenses.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    VStack(spacing: 8) {
                        Text("No Expenses Yet")
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        
                        Text("Add your first expense above to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .leading) // 👈 removes right gap
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.95, green: 0.97, blue: 1.0),
                                    Color(red: 0.9, green: 0.94, blue: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(.black.opacity(0.08), lineWidth: 1)
                        )
                )
            } else {
                ForEach(groupedExpenses.keys.sorted(by: >), id: \.self) { day in
                    let items = groupedExpenses[day] ?? []
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(day.formatted(date: .abbreviated, time: .omitted))
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(trip.currency.symbol)\(items.reduce(0, {$0 + $1.amount}), specifier: "%.2f")")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(trip.currency.gradient)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }

                        VStack(spacing: 8) {
                            ForEach(items) { expense in
                                ExpenseRow(
                                    trip: trip,
                                    expense: expense,
                                    onDelete: { pendingDelete = expense }
                                )
                                .onTapGesture { editExpense = expense }
                                .contextMenu {
                                    Button("Edit", systemImage: "pencil") { editExpense = expense }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        pendingDelete = expense
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.2, green: 0.2, blue: 0.3),
                                        Color(red: 0.15, green: 0.15, blue: 0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(.white.opacity(0.1), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    )
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, .mint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Summary")
                    .font(.headline.bold())
                    .foregroundColor(.white)
                Spacer()
            }
            
            HStack(spacing: 12) {
                SummaryPill(title: "Total", value: trip.totalAmount, symbol: trip.currency.symbol, gradient: trip.currency.gradient)
                SummaryPill(title: "Per Person", value: trip.members.isEmpty ? 0 : trip.totalAmount / Double(trip.members.count), symbol: trip.currency.symbol, gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                SummaryPill(title: "Transactions", value: Double(trip.transactionsCount), symbol: "", format: "%.0f", gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.2, blue: 0.3),
                            Color(red: 0.15, green: 0.15, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }

    private var balancesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Balances")
                    .font(.headline.bold())
                    .foregroundColor(.white)
                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(trip.balances, id: \.0.id) { (member, balance) in
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.cyan)
                            Text(member.name)
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                        
                        if abs(balance) < 0.01 {
                            Text("✓ Settled")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    LinearGradient(
                                        colors: [.green, .mint],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        } else {
                            HStack(spacing: 8) {
                                Text("\(trip.currency.symbol)\(abs(balance), specifier: "%.2f")")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Text(balance > 0 ? "gets back" : "owes")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        LinearGradient(
                                            colors: balance > 0 ? [.green, .mint] : [.red, .orange],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.25))
                            .stroke(.white.opacity(0.05), lineWidth: 1)
                    )
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.2, blue: 0.3),
                            Color(red: 0.15, green: 0.15, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }

    private var canAdd: Bool {
        !newExpense.note.isEmpty &&
        (Double(amountInput) ?? 0) > 0 &&
        trip.members.contains { $0.id == newExpense.paidBy } &&
        !newExpense.splitWith.isEmpty
    }

    private func addExpense() {
        newExpense.amount = Double(amountInput) ?? 0
        var e = newExpense
        e.id = UUID()
        if e.splitWith.isEmpty { e.splitWith = trip.members.map { $0.id } }
        store.addExpense(e, to: trip.id)

        newExpense = Expense(
            note: "",
            amount: 0,
            paidBy: trip.members.first?.id ?? UUID(),
            splitWith: trip.members.map { $0.id }
        )
        amountInput = ""
    }

    private var groupedExpenses: [Date: [Expense]] {
        Dictionary(grouping: trip.expenses) { Calendar.current.startOfDay(for: $0.date) }
    }

    private func memberName(_ id: UUID) -> String {
        trip.members.first(where: { $0.id == id })?.name ?? "N/A"
    }
}

struct SummaryPill: View {
    let title: String
    let value: Double
    let symbol: String
    var format: String = "%.2f"
    let gradient: LinearGradient

    private var formatted: String {
        String(format: format, value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            
            Text("\(symbol)\(formatted)")
                .font(.title3.bold())
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(gradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
    }
}

struct ExpenseRow: View {
    let trip: Trip
    let expense: Expense
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "creditcard.fill")
                .font(.title3)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(expense.note)
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                        Text("Paid by \(memberName(expense.paidBy))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))

                    Text("Split \(splitSummary)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(trip.currency.symbol)\(expense.amount, specifier: "%.2f")")
                    .font(.body.bold())
                    .foregroundColor(.white)
                
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func memberName(_ id: UUID) -> String {
        trip.members.first(where: { $0.id == id })?.name ?? "—"
    }

    private var splitSummary: String {
        if expense.splitWith.count == trip.members.count { return "equally" }
        return "among \(expense.splitWith.count)"
    }
}

// MARK: - Components
struct ToggleMultiPicker<Option: Identifiable & Hashable & CustomStringConvertible>: View where Option.ID == UUID {
    var options: [Option]
    @Binding var selection: [Option.ID]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.element.id) { _, option in
                let isOn = selection.contains(option.id)
                Button(action: { toggle(option.id) }) {
                    HStack(spacing: 6) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14))
                        Text(option.description)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            isOn ?
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ) :
                            LinearGradient(
                                colors: [Color(red: 0.15, green: 0.15, blue: 0.25), Color(red: 0.1, green: 0.1, blue: 0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(isOn ? .white.opacity(0.3) : .white.opacity(0.1), lineWidth: 1)
                        )
                )
                .foregroundColor(.white)
                .shadow(color: isOn ? .cyan.opacity(0.3) : .clear, radius: 4, x: 0, y: 2)
            }
        }
    }

    private func toggle(_ id: Option.ID) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else {
            selection.append(id)
        }
    }
}

extension Member: CustomStringConvertible { var description: String { name } }

struct TripExpenseApp: App {
    var body: some Scene {
        WindowGroup {
            TripListView()
                .environmentObject(TripStore())
        }
    }
}

// MARK: - Previews
struct TripExpense_Previews: PreviewProvider {
    static var previews: some View {
        TripListView().environmentObject(TripStore())
    }
}
