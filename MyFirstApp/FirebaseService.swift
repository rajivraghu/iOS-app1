import Foundation
import FirebaseFirestore
import FirebaseStorage

final class FirebaseService {
    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    // MARK: - Public API
    func fetchTrips(completion: @escaping ([Trip]) -> Void) {
        db.collection("trips")
            .order(by: "createdAt", descending: true)
            .getDocuments { [weak self] snapshot, error in
                guard error == nil, let snapshot else { completion([]); return }

                if snapshot.documents.isEmpty { completion([]); return }

                var results: [Trip] = []
                let outer = DispatchGroup()

                for doc in snapshot.documents {
                    outer.enter()
                    var trip = self?.tripFrom(doc: doc) ?? Trip(name: "")

                    let inner = DispatchGroup()
                    // Members
                    inner.enter()
                    self?.db.collection("trips").document(doc.documentID).collection("members")
                        .getDocuments { mSnap, _ in
                            if let mSnap {
                                trip.members = mSnap.documents.compactMap { self?.memberFrom(doc: $0) }
                            }
                            inner.leave()
                        }
                    // Expenses
                    inner.enter()
                    self?.db.collection("trips").document(doc.documentID).collection("expenses")
                        .order(by: "date", descending: true)
                        .getDocuments { eSnap, _ in
                            if let eSnap {
                                trip.expenses = eSnap.documents.compactMap { self?.expenseFrom(doc: $0) }
                            }
                            inner.leave()
                        }

                    inner.notify(queue: .global()) {
                        results.append(trip)
                        outer.leave()
                    }
                }

                outer.notify(queue: .main) {
                    results.sort { $0.createdAt > $1.createdAt }
                    completion(results)
                }
            }
    }

    func saveTrip(_ trip: Trip, completion: @escaping (Error?) -> Void) {
        let ref = db.collection("trips").document(trip.id.uuidString)
        ref.setData(tripDict(trip), merge: true) { [weak self] error in
            if let error { completion(error); return }
            self?.syncMembers(trip) { memberError in
                if let memberError { completion(memberError); return }
                self?.uploadTripSnapshotToStorage(trip)
                completion(nil)
            }
        }
    }

    func updateTrip(_ trip: Trip, completion: @escaping (Error?) -> Void) {
        saveTrip(trip, completion: completion)
    }

    func deleteTrip(_ tripID: UUID, completion: @escaping (Error?) -> Void) {
        let tripDoc = db.collection("trips").document(tripID.uuidString)
        // Delete subcollections first
        let group = DispatchGroup()
        var opError: Error?

        group.enter()
        tripDoc.collection("members").getDocuments { snap, err in
            if let err { opError = err; group.leave(); return }
            let batch = self.db.batch()
            snap?.documents.forEach { batch.deleteDocument($0.reference) }
            batch.commit { err in opError = opError ?? err; group.leave() }
        }

        group.enter()
        tripDoc.collection("expenses").getDocuments { snap, err in
            if let err { opError = err; group.leave(); return }
            let batch = self.db.batch()
            snap?.documents.forEach { batch.deleteDocument($0.reference) }
            batch.commit { err in opError = opError ?? err; group.leave() }
        }

        group.notify(queue: .global()) {
            if let opError { completion(opError); return }
            tripDoc.delete { error in
                completion(error)
            }
        }
    }

    func saveExpense(_ expense: Expense, to tripID: UUID, completion: @escaping (Error?) -> Void) {
        let ref = db.collection("trips").document(tripID.uuidString).collection("expenses").document(expense.id.uuidString)
        ref.setData(expenseDict(expense), merge: true) { [weak self] error in
            if let error { completion(error); return }
            self?.refreshTripSnapshotForStorage(tripID: tripID)
            completion(nil)
        }
    }

    func updateExpense(_ expense: Expense, in tripID: UUID, completion: @escaping (Error?) -> Void) {
        saveExpense(expense, to: tripID, completion: completion)
    }

    func deleteExpense(_ expenseID: UUID, in tripID: UUID, completion: @escaping (Error?) -> Void) {
        let ref = db.collection("trips").document(tripID.uuidString).collection("expenses").document(expenseID.uuidString)
        ref.delete { [weak self] error in
            if let error { completion(error); return }
            self?.refreshTripSnapshotForStorage(tripID: tripID)
            completion(nil)
        }
    }

    // MARK: - Helpers (Firestore Mapping)
    private func tripDict(_ t: Trip) -> [String: Any] {
        return [
            "id": t.id.uuidString,
            "name": t.name,
            "detail": t.detail,
            "currency": t.currency.rawValue,
            "createdAt": Timestamp(date: t.createdAt)
        ]
    }

    private func expenseDict(_ e: Expense) -> [String: Any] {
        return [
            "id": e.id.uuidString,
            "date": Timestamp(date: e.date),
            "note": e.note,
            "amount": e.amount,
            "paidBy": e.paidBy.uuidString,
            "splitWith": e.splitWith.map { $0.uuidString }
        ]
    }

    private func memberDict(_ m: Member) -> [String: Any] {
        return [
            "id": m.id.uuidString,
            "name": m.name
        ]
    }

    private func tripFrom(doc: DocumentSnapshot) -> Trip {
        let data = doc.data() ?? [:]
        let id = UUID(uuidString: (data["id"] as? String) ?? doc.documentID) ?? UUID()
        let name = data["name"] as? String ?? ""
        let detail = data["detail"] as? String ?? ""
        let currencyRaw = data["currency"] as? String ?? Currency.usd.rawValue
        let currency = Currency(rawValue: currencyRaw) ?? .usd
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        return Trip(id: id, name: name, detail: detail, currency: currency, createdAt: createdAt, members: [], expenses: [])
    }

    private func expenseFrom(doc: DocumentSnapshot) -> Expense? {
        guard let data = doc.data() else { return nil }
        let id = UUID(uuidString: (data["id"] as? String) ?? doc.documentID) ?? UUID()
        let date = (data["date"] as? Timestamp)?.dateValue() ?? Date()
        let note = data["note"] as? String ?? ""
        let amount = data["amount"] as? Double ?? 0
        let paidBy = UUID(uuidString: data["paidBy"] as? String ?? "") ?? UUID()
        let splitWithStr = data["splitWith"] as? [String] ?? []
        let splitWith = splitWithStr.compactMap { UUID(uuidString: $0) }
        return Expense(id: id, date: date, note: note, amount: amount, paidBy: paidBy, splitWith: splitWith)
    }

    private func memberFrom(doc: DocumentSnapshot) -> Member? {
        guard let data = doc.data() else { return nil }
        let id = UUID(uuidString: (data["id"] as? String) ?? doc.documentID) ?? UUID()
        let name = data["name"] as? String ?? ""
        return Member(id: id, name: name)
    }

    private func syncMembers(_ trip: Trip, completion: ((Error?) -> Void)? = nil) {
        let membersRef = db.collection("trips").document(trip.id.uuidString).collection("members")
        // Fetch existing and delete missing
        membersRef.getDocuments { [weak self] snap, err in
            if let err { completion?(err); return }

            let existingIDs = Set((snap?.documents ?? []).map { $0.documentID })
            let currentIDs = Set(trip.members.map { $0.id.uuidString })

            // Delete removed
            let toDelete = existingIDs.subtracting(currentIDs)
            let batch = self?.db.batch()
            toDelete.forEach { id in
                batch?.deleteDocument(membersRef.document(id))
            }

            // Upsert current
            trip.members.forEach { m in
                batch?.setData(self?.memberDict(m) ?? [:], forDocument: membersRef.document(m.id.uuidString), merge: true)
            }

            batch?.commit { commitError in
                completion?(commitError)
            }
        }
    }

    // MARK: - Storage JSON Snapshot (optional backup)
    private func uploadTripSnapshotToStorage(_ trip: Trip) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(trip)
            let ref = storage.reference().child("trips/\(trip.id.uuidString).json")
            let metadata = StorageMetadata()
            metadata.contentType = "application/json"
            ref.putData(data, metadata: metadata) { _, _ in }
        } catch {
            // Best-effort; ignore snapshot failures
        }
    }

    private func refreshTripSnapshotForStorage(tripID: UUID) {
        // Fetch the trip fully and upload a fresh snapshot
        db.collection("trips").document(tripID.uuidString).getDocument { [weak self] doc, _ in
            guard let self, let doc else { return }
            var trip = self.tripFrom(doc: doc)
            let group = DispatchGroup()

            group.enter()
            self.db.collection("trips").document(doc.documentID).collection("members").getDocuments { mSnap, _ in
                if let mSnap { trip.members = mSnap.documents.compactMap { self.memberFrom(doc: $0) } }
                group.leave()
            }

            group.enter()
            self.db.collection("trips").document(doc.documentID).collection("expenses").getDocuments { eSnap, _ in
                if let eSnap { trip.expenses = eSnap.documents.compactMap { self.expenseFrom(doc: $0) } }
                group.leave()
            }

            group.notify(queue: .global()) {
                self.uploadTripSnapshotToStorage(trip)
            }
        }
    }
}
