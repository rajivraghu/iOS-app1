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
        case .aud: return "A$"
        case .cad: return "C$"
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
    
    // Uncomment this line to enable Firebase
    private let firebase = FirebaseService()
    
    // This is no longer needed but can be kept for fallback/local testing
    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("TripExpenseData.json")
    }()
    
    init() {
        // Load data from Firebase on initialization
        self.loadFromFirebase()
    }
    
    // New method to load from Firebase
    func loadFromFirebase() {
        firebase.fetchTrips { [weak self] fetchedTrips in
            DispatchQueue.main.async {
                self?.trips = fetchedTrips
                // Remove the seedSampleData() call to stop creating dummy data
            }
        }
    }
    
    private func seedSampleData() {
        let sample = Trip(
            name: "Switzerland Trip",
            detail: "An amazing adventure in the Alps!",
            currency: .eur,
            createdAt: Date(),
            members: [Member(name: "Alex"), Member(name: "Vaihi")],
            expenses: []
        )
        self.addTrip(sample)
    }
    
    // MARK: Mutations
    func addTrip(_ trip: Trip) {
        firebase.saveTrip(trip) { [weak self] error in
            if let error = error {
                print("Error saving trip to Firebase: \(error)")
            } else {
                self?.loadFromFirebase() // Refresh data from Firebase
            }
        }
    }
    
    func updateTrip(_ trip: Trip) {
        firebase.updateTrip(trip) { [weak self] error in
            if let error = error {
                print("Error updating trip in Firebase: \(error)")
            } else {
                self?.loadFromFirebase()
            }
        }
    }
    
    func deleteTrips(at offsets: IndexSet) {
        for index in offsets {
            let tripToDelete = trips[index]
            firebase.deleteTrip(tripToDelete.id) { [weak self] error in
                if let error = error {
                    print("Error deleting trip from Firebase: \(error)")
                } else {
                    self?.loadFromFirebase()
                }
            }
        }
    }
    
    func addExpense(_ expense: Expense, to tripID: UUID) {
        firebase.saveExpense(expense, to: tripID) { [weak self] error in
            if let error = error {
                print("Error adding expense to Firebase: \(error)")
            } else {
                self?.loadFromFirebase()
            }
        }
    }
    
    func updateExpense(_ expense: Expense, in tripID: UUID) {
        firebase.updateExpense(expense, in: tripID) { [weak self] error in
            if let error = error {
                print("Error updating expense in Firebase: \(error)")
            } else {
                self?.loadFromFirebase()
            }
        }
    }
    
    func deleteExpense(_ expenseID: UUID, in tripID: UUID) {
        firebase.deleteExpense(expenseID, in: tripID) { [weak self] error in
            if let error = error {
                print("Error deleting expense from Firebase: \(error)")
            } else {
                self?.loadFromFirebase()
            }
        }
    }
}

// MARK: - THEME DEFINITION
extension Color {
    static let appBackground = LinearGradient(
        colors: [Color.white, Color.cyan.opacity(0.3), Color.blue.opacity(0.5)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let primaryButtonGradient = LinearGradient(
        colors: [.cyan, .blue],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    static let disabledButtonGradient = LinearGradient(
        colors: [.gray.opacity(0.3), .gray.opacity(0.5)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - VIEWS
struct TripListView: View {
    @EnvironmentObject var store: TripStore
    @State private var showNewTrip = false
    @State private var editingTrip: Trip? = nil
    @State private var search = ""
    @State private var tripToCreate = Trip(name: "")
    @State private var tripToDelete: Trip? = nil
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                
                List {
                    if store.trips.isEmpty {
                        emptyStateView
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredTrips) { trip in
                            NavigationLink(value: trip) {
                                TripCard(trip: trip)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
                ToolbarItem(placement: .principal) {
                    Text("TripExpense")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.primaryButtonGradient)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        tripToCreate = Trip(name: "")
                        showNewTrip = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("New")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primaryButtonGradient)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: boundTrip(trip))
            }
            .confirmationDialog(
                "Delete this trip?",
                isPresented: Binding(get: { tripToDelete != nil }, set: { if !$0 { tripToDelete = nil } }),
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
    
    private var emptyStateView: some View {
        VStack(spacing: 30) {
            Spacer().frame(height: 100)
            Image(systemName: "map.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(spacing: 12) {
                Text("Ready for Adventure?")
                    .font(.title.bold())
                Text("Create your first trip to start tracking expenses")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
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

// MARK: - UNIFIED TRIP CARD
struct TripCard: View {
    var trip: Trip
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.name)
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    if !trip.detail.isEmpty {
                        Text(trip.detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
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
            }
            
            HStack(spacing: 20) {
                Label("\(trip.members.count)", systemImage: "person.2.fill")
                Label(trip.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Spent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(trip.currency.symbol)\(trip.totalAmount, specifier: "%.2f")")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Transactions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(trip.transactionsCount)")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                }
            }
        }
        .modifier(SectionCardModifier())
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
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SectionHeader(title: "Trip Information")
                        SectionCard {
                            VStack(spacing: 12) {
                                LabeledTextField(label: "Trip Name", placeholder: "Enter trip name", text: $trip.name)
                                LabeledTextField(label: "Description", placeholder: "Add a short description", text: $trip.detail, axis: .vertical)
                                
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
                                            .background(Color.primaryButtonGradient)
                                            .clipShape(Circle())
                                    }
                                    .disabled(memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                
                                if trip.members.isEmpty {
                                    Text("No members yet").foregroundColor(.secondary).italic()
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(trip.members) { member in
                                            HStack(spacing: 12) {
                                                Image(systemName: "person.crop.circle.fill").foregroundColor(.cyan)
                                                Text(member.name)
                                                Spacer()
                                                Button(role: .destructive) {
                                                    trip.members.removeAll { $0.id == member.id }
                                                } label: {
                                                    Image(systemName: "trash").foregroundColor(.red)
                                                }
                                            }
                                            .padding(10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.white.opacity(0.9))
                                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.05), lineWidth: 1))
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { save() }
                        .disabled(trip.name.isEmpty || trip.members.isEmpty)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(trip.name.isEmpty || trip.members.isEmpty ? Color.disabledButtonGradient : Color.primaryButtonGradient)
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

// MARK: - Expense Editor (Refactored to match TripEditor)
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
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SectionHeader(title: "Expense Details")
                        SectionCard {
                            VStack(spacing: 12) {
                                LabeledDatePicker(label: "Date", selection: $expense.date)
                                LabeledTextField(label: "Description", placeholder: "e.g., Dinner, Tickets", text: $expense.note)
                                LabeledCurrencyField(label: "Amount", amount: $expense.amount, currencySymbol: trip.currency.symbol)
                                LabeledPicker(label: "Paid by", selection: $expense.paidBy) {
                                    ForEach(trip.members) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                }
                            }
                        }
                        
                        SectionHeader(title: "Split With")
                        SectionCard {
                            ToggleMultiPicker(options: trip.members, selection: $expense.splitWith)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.light)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primaryButtonGradient)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    private func save() {
        if expense.splitWith.isEmpty {
            expense.splitWith = trip.members.map { $0.id }
        }
        store.updateExpense(expense, in: trip.id)
        dismiss()
    }
}


// MARK: - Trip Detail & Expenses (Refactored with clean UI)
struct TripDetailView: View {
    @EnvironmentObject var store: TripStore
    @Binding var trip: Trip
    @State private var newExpense = Expense(note: "", amount: 0, paidBy: UUID(), splitWith: [])
    @State private var editExpense: Expense? = nil
    @State private var amountInput: String = ""
    @State private var pendingDelete: Expense? = nil
    
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addExpenseCard
                    expenseList
                    summaryCard
                    balancesCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .sheet(item: $editExpense) { exp in
            ExpenseEditor(trip: $trip, expense: exp)
        }
        .onAppear {
            // Setup default values for new expense
            if !trip.members.contains(where: { $0.id == newExpense.paidBy }) {
                newExpense.paidBy = trip.members.first?.id ?? UUID()
            }
            if newExpense.splitWith.isEmpty {
                newExpense.splitWith = trip.members.map { $0.id }
            }
        }
        .confirmationDialog("Delete this expense?", isPresented: .constant(pendingDelete != nil), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let exp = pendingDelete { store.deleteExpense(exp.id, in: trip.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let exp = pendingDelete {
                Text("\"\(exp.note)\" · \(trip.currency.symbol)\(exp.amount, specifier: "%.2f")")
            }
        }
    }
    
    private var addExpenseCard: some View {
        SectionCard {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Color.primaryButtonGradient)
                    Text("Add New Expense").font(.headline.bold())
                    Spacer()
                }
                
                TextField("What was this for?", text: $newExpense.note).inputField()
                DatePicker("Date", selection: $newExpense.date, displayedComponents: .date).inputField()
                
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("0.00", text: $amountInput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text(trip.currency.symbol)
                }
                .inputField()
                
                HStack {
                    Text("Paid by")
                    Spacer()
                    Menu {
                        Picker("Paid by", selection: $newExpense.paidBy) {
                            ForEach(trip.members) { m in Text(m.name).tag(m.id) }
                        }
                    } label: {
                        HStack {
                            Text(memberName(newExpense.paidBy))
                            Image(systemName: "chevron.up.chevron.down").foregroundColor(.secondary)
                        }
                    }
                }
                .inputField()
                
                VStack(alignment: .leading) {
                    Text("Split with").padding(.leading, 4)
                    ToggleMultiPicker(options: trip.members, selection: $newExpense.splitWith)
                }
                
                Button(action: addExpense) {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add Expense")
                    }
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canAdd ? Color.primaryButtonGradient : Color.disabledButtonGradient)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canAdd)
            }
        }
    }
    
    private var expenseList: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Expenses")
            
            if trip.expenses.isEmpty {
                SectionCard {
                    Text("No expenses yet. Add one above to get started!")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            } else {
                ForEach(groupedExpenses.keys.sorted(by: >), id: \.self) { day in
                    let items = groupedExpenses[day] ?? []
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(day.formatted(date: .abbreviated, time: .omitted))
                                    .font(.headline)
                                Spacer()
                                Text("\(trip.currency.symbol)\(items.reduce(0, {$0 + $1.amount}), specifier: "%.2f")")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.secondary)
                            }
                            
                            ForEach(items) { expense in
                                ExpenseRow(trip: trip, expense: expense)
                                    .onTapGesture { editExpense = expense }
                                    .contextMenu {
                                        Button("Edit", systemImage: "pencil") { editExpense = expense }
                                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = expense }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Summary")
            SectionCard {
                HStack(spacing: 12) {
                    SummaryPill(title: "Total", value: trip.totalAmount, symbol: trip.currency.symbol, gradient: trip.currency.gradient)
                    SummaryPill(title: "Per Person", value: trip.members.isEmpty ? 0 : trip.totalAmount / Double(trip.members.count), symbol: trip.currency.symbol, gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    SummaryPill(title: "Items", value: Double(trip.transactionsCount), symbol: "", format: "%.0f", gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
    }
    
    private var balancesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Balances")
            SectionCard {
                VStack(spacing: 12) {
                    ForEach(trip.balances, id: \.0.id) { (member, balance) in
                        HStack {
                            Text(member.name)
                            Spacer()
                            
                            if abs(balance) < 0.01 {
                                Text("Settled Up").font(.subheadline.bold()).foregroundColor(.green)
                            } else {
                                Text("\(trip.currency.symbol)\(abs(balance), specifier: "%.2f")")
                                    .font(.subheadline.bold())
                                    .foregroundColor(balance > 0 ? .green : .orange)
                                Text(balance > 0 ? "gets back" : "owes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    private var canAdd: Bool {
        !newExpense.note.isEmpty && (Double(amountInput) ?? 0) > 0 && !newExpense.splitWith.isEmpty
    }
    
    private func addExpense() {
        newExpense.amount = Double(amountInput) ?? 0
        var e = newExpense
        e.id = UUID()
        if e.splitWith.isEmpty { e.splitWith = trip.members.map { $0.id } }
        store.addExpense(e, to: trip.id)
        
        newExpense = Expense(note: "", amount: 0, paidBy: trip.members.first?.id ?? UUID(), splitWith: trip.members.map { $0.id })
        amountInput = ""
    }
    
    private var groupedExpenses: [Date: [Expense]] {
        Dictionary(grouping: trip.expenses) { Calendar.current.startOfDay(for: $0.date) }
    }
    
    private func memberName(_ id: UUID) -> String {
        trip.members.first(where: { $0.id == id })?.name ?? "N/A"
    }
}


// MARK: - Reusable Components
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title2.bold())
            .foregroundColor(.primary.opacity(0.9))
            .padding(.leading, 4)
    }
}

private struct SectionCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.95, green: 0.97, blue: 1.0).opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.06), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
            )
    }
}
private extension View {
    func SectionCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .modifier(SectionCardModifier())
    }
}

private struct InputBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08), lineWidth: 1))
            )
    }
}
private extension View {
    func inputField() -> some View { self.modifier(InputBackground()) }
}

struct LabeledTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundColor(.secondary)
            if axis == .vertical {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .inputField()
            } else {
                TextField(placeholder, text: $text).inputField()
            }
        }
    }
}

struct LabeledDatePicker: View {
    let label: String
    @Binding var selection: Date
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundColor(.secondary)
            DatePicker(label, selection: $selection, displayedComponents: .date)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .inputField()
        }
    }
}

struct LabeledCurrencyField: View {
    let label: String
    @Binding var amount: Double
    let currencySymbol: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundColor(.secondary)
            HStack {
                Text(currencySymbol)
                TextField("0.00", value: $amount, format: .number).keyboardType(.decimalPad)
            }.inputField()
        }
    }
}

struct LabeledPicker<Content: View>: View {
    let label: String
    @Binding var selection: UUID
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundColor(.secondary)
            HStack {
                Picker(label, selection: $selection) { content() }
                Spacer()
            }
            .labelsHidden()
            .inputField()
        }
    }
}

struct SummaryPill: View {
    let title: String
    let value: Double
    let symbol: String
    var format: String = "%.2f"
    let gradient: LinearGradient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.white.opacity(0.8))
            Text("\(symbol)\(String(format: format, value))")
                .font(.headline.bold()).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(gradient)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
    }
}

struct ExpenseRow: View {
    let trip: Trip
    let expense: Expense
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(expense.note).font(.headline)
                Text("Paid by \(memberName(expense.paidBy)) · Split \(splitSummary)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(trip.currency.symbol)\(expense.amount, specifier: "%.2f")")
                .font(.body.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
    
    private func memberName(_ id: UUID) -> String {
        trip.members.first(where: { $0.id == id })?.name ?? "N/A"
    }
    private var splitSummary: String {
        if expense.splitWith.count == trip.members.count { return "equally" }
        return "among \(expense.splitWith.count)"
    }
}

struct ToggleMultiPicker<Option: Identifiable & Hashable & CustomStringConvertible>: View where Option.ID == UUID {
    var options: [Option]
    @Binding var selection: [Option.ID]
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(options) { option in
                let isOn = selection.contains(option.id)
                Button(action: { toggle(option.id) }) {
                    HStack(spacing: 6) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        Text(option.description).lineLimit(1)
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(isOn ? .white : .primary.opacity(0.8))
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(isOn ? Color.primaryButtonGradient : LinearGradient(colors: [Color.white.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    )
                }
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

