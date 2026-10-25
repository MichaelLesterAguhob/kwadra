typedef Json = Map<String, dynamic>;

class RentalProperty {
  const RentalProperty({
    required this.id,
    required this.name,
    required this.address,
    required this.type,
    required this.image,
    this.notes = '',
    this.details = const {},
    this.archived = false,
    this.revision = 0,
  });
  final int revision;
  final String id, name, address, type, image, notes;
  final bool archived;
  final Json details;
  Json toJson() => {
    'id': id,
    'revision': revision,
    'name': name,
    'address': address,
    'type': type,
    'image': image,
    'notes': notes,
    'details': details,
    'archived': archived,
  };
  factory RentalProperty.fromJson(Json j) => RentalProperty(
    id: j['id'],
    revision: j['revision'] ?? 0,
    name: j['name'],
    address: j['address'],
    type: j['type'],
    image: j['image'],
    notes: j['notes'] ?? '',
    details: Json.from(j['details'] ?? {}),
    archived: j['archived'] ?? false,
  );
}

class RentalUnit {
  const RentalUnit({
    required this.id,
    required this.propertyId,
    required this.code,
    required this.type,
    required this.rent,
    this.notes = '',
    this.capacity = 2,
    this.floor = 'Ground floor',
    this.maintenance = false,
    this.revision = 0,
  });
  final int revision;
  final String id, propertyId, code, type, floor, notes;
  final int rent, capacity;
  final bool maintenance;
  Json toJson() => {
    'id': id,
    'revision': revision,
    'propertyId': propertyId,
    'code': code,
    'type': type,
    'rent': rent,
    'capacity': capacity,
    'floor': floor,
    'maintenance': maintenance,
    'notes': notes,
  };
  factory RentalUnit.fromJson(Json j) => RentalUnit(
    id: j['id'],
    revision: j['revision'] ?? 0,
    propertyId: j['propertyId'],
    code: j['code'],
    type: j['type'],
    rent: j['rent'],
    capacity: j['capacity'],
    floor: j['floor'],
    maintenance: j['maintenance'] ?? false,
    notes: j['notes'] ?? '',
  );
}

class Tenant {
  const Tenant({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    this.emergency = '',
    this.archived = false,
    this.revision = 0,
  });
  final int revision;
  final String id, name, email, phone, emergency;
  final bool archived;
  Json toJson() => {
    'id': id,
    'revision': revision,
    'name': name,
    'email': email,
    'phone': phone,
    'emergency': emergency,
    'archived': archived,
  };
  factory Tenant.fromJson(Json j) => Tenant(
    id: j['id'],
    revision: j['revision'] ?? 0,
    name: j['name'],
    email: j['email'],
    phone: j['phone'],
    emergency: j['emergency'] ?? '',
    archived: j['archived'] ?? false,
  );
}

class Lease {
  const Lease({
    required this.id,
    required this.unitId,
    required this.tenantIds,
    required this.start,
    required this.end,
    required this.rent,
    required this.dueDay,
    this.deposit = 0,
    this.ended = false,
    this.draft = false,
    this.cancelled = false,
    this.occupancyEnd,
    this.revision = 0,
  });
  final int revision;
  final String id, unitId;
  final List<String> tenantIds;
  final DateTime start, end;
  final DateTime? occupancyEnd;
  final int rent, dueDay, deposit;
  final bool ended, cancelled, draft;
  bool activeAt(DateTime day) =>
      !draft && !ended && !day.isBefore(start) && !day.isAfter(end);
  bool occupiedAt(DateTime day) =>
      !draft &&
      !cancelled &&
      !day.isBefore(start) &&
      (occupancyEnd != null
          ? day.isBefore(occupancyEnd!)
          : ended
          ? day.isBefore(end)
          : !day.isAfter(end));
  Json toJson() => {
    'id': id,
    'revision': revision,
    'unitId': unitId,
    'tenantIds': tenantIds,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'rent': rent,
    'dueDay': dueDay,
    'deposit': deposit,
    'ended': ended,
    'draft': draft,
    'cancelled': cancelled,
    if (occupancyEnd != null) 'occupancyEnd': occupancyEnd!.toIso8601String(),
  };
  factory Lease.fromJson(Json j) => Lease(
    id: j['id'],
    revision: j['revision'] ?? 0,
    unitId: j['unitId'],
    tenantIds: List<String>.from(j['tenantIds']),
    start: DateTime.parse(j['start']),
    end: DateTime.parse(j['end']),
    rent: j['rent'],
    dueDay: j['dueDay'],
    deposit: j['deposit'] ?? 0,
    ended: j['ended'] ?? false,
    draft: j['draft'] ?? false,
    cancelled: j['cancelled'] ?? false,
    occupancyEnd: j['occupancyEnd'] == null
        ? null
        : DateTime.parse(j['occupancyEnd']),
  );
}

class RentInvoice {
  const RentInvoice({
    required this.id,
    required this.number,
    required this.leaseId,
    required this.period,
    required this.due,
    required this.amount,
    this.kind = 'rent',
  });
  final String id, number, leaseId, period, kind;
  final DateTime due;
  final int amount;
  Json toJson() => {
    'id': id,
    'number': number,
    'leaseId': leaseId,
    'period': period,
    'due': due.toIso8601String(),
    'amount': amount,
    'kind': kind,
  };
  factory RentInvoice.fromJson(Json j) => RentInvoice(
    id: j['id'],
    number: j['number'],
    leaseId: j['leaseId'],
    period: j['period'],
    due: DateTime.parse(j['due']),
    amount: j['amount'],
    kind: j['kind'] ?? 'rent',
  );
}

class MaintenanceTicket {
  const MaintenanceTicket({
    required this.id,
    required this.unitId,
    required this.title,
    required this.description,
    required this.category,
    required this.priority,
    required this.status,
    required this.created,
    this.history = const [],
    this.revision = 0,
  });
  final int revision;
  final String id, unitId, title, description, category, priority, status;
  final DateTime created;
  final List<String> history;
  Json toJson() => {
    'id': id,
    'revision': revision,
    'unitId': unitId,
    'title': title,
    'description': description,
    'category': category,
    'priority': priority,
    'status': status,
    'created': created.toIso8601String(),
    'history': history,
  };
  factory MaintenanceTicket.fromJson(Json j) => MaintenanceTicket(
    id: j['id'],
    revision: j['revision'] ?? 0,
    unitId: j['unitId'],
    title: j['title'],
    description: j['description'],
    category: j['category'],
    priority: j['priority'],
    status: j['status'],
    created: DateTime.parse(j['created']),
    history: List<String>.from(j['history'] ?? []),
  );
}

class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.title,
    required this.detail,
    required this.created,
    required this.kind,
  });
  final String id, title, detail, kind;
  final DateTime created;
  Json toJson() => {
    'id': id,
    'title': title,
    'detail': detail,
    'created': created.toIso8601String(),
    'kind': kind,
  };
  factory ActivityEvent.fromJson(Json j) => ActivityEvent(
    id: j['id'],
    title: j['title'],
    detail: j['detail'],
    kind: j['kind'],
    created: DateTime.parse(j['created']),
  );
}
