import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/formatters.dart';
import 'api_client.dart';
import 'models.dart';

/// Shared view model. The app uses the API; open() retains the explicit local
/// demonstration and its saved data for compatibility and offline UI tests.
class WorkspaceStore extends ChangeNotifier {
  WorkspaceStore._(this._preferences, this._clock);
  static const storageKey = 'kwadra.workspace.v1';
  final SharedPreferences _preferences;
  final DateTime Function() _clock;
  ApiClient? _api;
  bool get isRemote => _api != null;
  bool get canWrite => !isRemote || permissions['canWrite'] == true;
  bool get canManage => !isRemote || permissions['canManage'] == true;
  bool get canManageTenants =>
      canWrite && (!isRemote || permissions['allProperties'] == true);
  String get apiUrl => _api?.baseUrl ?? '';
  List<Json> get organizations => _api?.organizations ?? [];
  String? get organizationId => _api?.organizationId;
  void selectOrganization(String id) => _api?.onOrganizationChanged?.call(id);
  Future<Json> backendGet(String path) {
    if (_api == null) {
      throw StateError('This feature needs the backend connection.');
    }
    return _api!.request('GET', path);
  }

  Future<Json> backendCommand(
    String path,
    Json body, {
    String method = 'POST',
  }) => _writeRemote(method, path, body);
  int revision = 0;
  Json permissions = {};
  bool refreshing = false;
  String? refreshError;
  DateTime? lastRefreshed, _serverToday;

  static Future<WorkspaceStore> connect(ApiClient api) async {
    final store = WorkspaceStore._(
      await SharedPreferences.getInstance(),
      DateTime.now,
    ).._api = api;
    await store._fetchRemote();
    return store;
  }

  Future<void> _fetchRemote() async {
    final data = await _api!.request('GET', '/workspace');
    final previous = toJson();
    try {
      _read(data);
    } catch (_) {
      _read(previous);
      rethrow;
    }
    revision = data['revision'] as int;
    permissions = Json.from(data['permissions'] as Map);
    _serverToday = DateTime.parse(data['today'] as String);
    lastRefreshed = DateTime.now();
    refreshError = null;
  }

  Future<T> _queued<T>(Future<T> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> refresh() => _queued(() async {
    if (!isRemote) return;
    refreshing = true;
    notifyListeners();
    try {
      await _fetchRemote();
    } catch (error) {
      refreshError = error.toString();
      rethrow;
    } finally {
      refreshing = false;
      notifyListeners();
    }
  });
  Future<Json> _writeRemote(
    String method,
    String path,
    Json body,
  ) => _queued(() async {
    final result = await _api!.request(method, path, body: body);
    // The write is committed even if the subsequent reload loses its connection.
    // Preserve that distinction so the user does not submit a second creation.
    try {
      await _fetchRemote();
    } catch (_) {
      refreshError =
          'Your change was saved. Refresh to load the latest records.';
    }
    notifyListeners();
    return result;
  });
  Future<void> signOut() async => _api?.logout();
  Future<void> _operations = Future.value();
  String ownerName = 'Alex Santos',
      organizationName = 'Kwadra Living',
      ownerEmail = 'alex@example.com';
  List<RentalProperty> _properties = [];
  List<RentalUnit> _units = [];
  List<Tenant> _tenants = [];
  List<Lease> _leases = [];
  List<RentInvoice> _invoices = [];
  List<MaintenanceTicket> _tickets = [];
  List<ActivityEvent> _activities = [];
  List<RentalProperty> get properties => List.unmodifiable(_properties);
  List<RentalProperty> get visibleProperties =>
      _properties.where((p) => !p.archived).toList();
  List<RentalUnit> get units => List.unmodifiable(_units);
  List<Tenant> get tenants => List.unmodifiable(_tenants);
  List<Lease> get leases => List.unmodifiable(_leases);
  List<RentInvoice> get invoices => List.unmodifiable(_invoices);
  List<MaintenanceTicket> get tickets => List.unmodifiable(_tickets);
  List<ActivityEvent> get activities => _activities.reversed.toList();
  // Philippine billing dates must not shift with the device's time zone.
  DateTime get today =>
      _serverToday ?? dateOnly(_clock().toUtc().add(const Duration(hours: 8)));
  static int _sequence = 0;
  String newId(String kind) => isRemote
      ? uuid()
      : '$kind-${_clock().microsecondsSinceEpoch}-${_sequence++}';

  static Future<WorkspaceStore> open({DateTime Function()? clock}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = WorkspaceStore._(prefs, clock ?? DateTime.now);
    final saved = prefs.getString(storageKey);
    if (saved == null) {
      store._seed();
      await store._persist();
    } else {
      store._read(jsonDecode(saved) as Json);
      store._validate();
    }
    return store;
  }

  RentalProperty property(String id) =>
      _properties.firstWhere((p) => p.id == id);
  RentalUnit unit(String id) => _units.firstWhere((u) => u.id == id);
  Tenant tenant(String id) => _tenants.firstWhere((t) => t.id == id);
  Lease lease(String id) => _leases.firstWhere((l) => l.id == id);
  List<RentalUnit> unitsFor(String id) =>
      _units.where((u) => u.propertyId == id).toList();
  List<Lease> leasesForUnit(String id) =>
      _leases.where((l) => l.unitId == id).toList();
  Lease? currentLease(String unitId) {
    for (final l in _leases) {
      if (l.unitId == unitId && l.activeAt(today)) return l;
    }
    return null;
  }

  List<Lease> get activeLeases =>
      _leases.where((l) => l.activeAt(today)).toList();
  List<RentalUnit> get visibleUnits =>
      _units.where((u) => !property(u.propertyId).archived).toList();
  int get occupiedCount =>
      visibleUnits.where((u) => currentLease(u.id) != null).length;
  int get availableCount => visibleUnits
      .where((u) => currentLease(u.id) == null && !u.maintenance)
      .length;
  int get monthlyRent => activeLeases.fold(0, (sum, l) => sum + l.rent);
  List<MaintenanceTicket> get openTickets =>
      _tickets.where((t) => t.status != 'Resolved').toList();
  String unitLabel(String id) =>
      '${property(unit(id).propertyId).name} · ${unit(id).code}';
  String leaseNames(Lease l) =>
      l.tenantIds.map((id) => tenant(id).name).join(', ');
  String unitStatus(RentalUnit u) => currentLease(u.id) != null
      ? 'Occupied'
      : u.maintenance
      ? 'Maintenance'
      : 'Available';

  Json toJson() => {
    'version': 1,
    'ownerName': ownerName,
    'ownerEmail': ownerEmail,
    'organizationName': organizationName,
    'properties': _properties.map((p) => p.toJson()).toList(),
    'units': _units.map((u) => u.toJson()).toList(),
    'tenants': _tenants.map((t) => t.toJson()).toList(),
    'leases': _leases.map((l) => l.toJson()).toList(),
    'invoices': _invoices.map((i) => i.toJson()).toList(),
    'tickets': _tickets.map((t) => t.toJson()).toList(),
    'activities': _activities.map((a) => a.toJson()).toList(),
  };
  String exportJson() => const JsonEncoder.withIndent('  ').convert(toJson());
  void _read(Json j) {
    if (j['version'] != 1) {
      throw const FormatException('Unsupported workspace version.');
    }
    ownerName = j['ownerName'] as String;
    organizationName = j['organizationName'] as String;
    ownerEmail = j['ownerEmail'] as String;
    _properties = (j['properties'] as List)
        .map((p) => RentalProperty.fromJson(Map<String, dynamic>.from(p)))
        .toList();
    _units = (j['units'] as List)
        .map((u) => RentalUnit.fromJson(Map<String, dynamic>.from(u)))
        .toList();
    _tenants = (j['tenants'] as List)
        .map((t) => Tenant.fromJson(Map<String, dynamic>.from(t)))
        .toList();
    _leases = (j['leases'] as List)
        .map((l) => Lease.fromJson(Map<String, dynamic>.from(l)))
        .toList();
    _invoices = (j['invoices'] as List)
        .map((i) => RentInvoice.fromJson(Map<String, dynamic>.from(i)))
        .toList();
    _tickets = (j['tickets'] as List)
        .map((t) => MaintenanceTicket.fromJson(Map<String, dynamic>.from(t)))
        .toList();
    _activities = (j['activities'] as List)
        .map((a) => ActivityEvent.fromJson(Map<String, dynamic>.from(a)))
        .toList();
  }

  Future<void> _persist() async {
    if (!await _preferences.setString(storageKey, jsonEncode(toJson()))) {
      throw StateError('Changes could not be saved. Check available storage.');
    }
  }

  Future<void> _mutate(void Function() operation) {
    final next = _operations.then((_) async {
      final before = jsonEncode(toJson());
      try {
        operation();
        _validate();
        await _persist();
        notifyListeners();
      } catch (_) {
        _read(jsonDecode(before) as Json);
        rethrow;
      }
    });
    _operations = next.catchError((Object _) {});
    return next;
  }

  void _event(String title, String detail, String kind) => _activities.add(
    ActivityEvent(
      id: newId('event'),
      title: title,
      detail: detail,
      created: _clock(),
      kind: kind,
    ),
  );

  void _validate() {
    if (ownerName.trim().isEmpty || organizationName.trim().isEmpty) {
      throw const FormatException('Workspace and owner names are required.');
    }
    void unique(Iterable<String> ids, String label) {
      final list = ids.toList();
      if (list.toSet().length != list.length || list.any((id) => id.isEmpty)) {
        throw FormatException('Duplicate or missing $label.');
      }
    }

    unique(_properties.map((p) => p.id), 'property IDs');
    unique(_units.map((u) => u.id), 'unit IDs');
    unique(_tenants.map((t) => t.id), 'tenant IDs');
    unique(_leases.map((l) => l.id), 'lease IDs');
    unique(_invoices.map((i) => i.id), 'invoice IDs');
    unique(_invoices.map((i) => i.number), 'invoice numbers');
    unique(_tickets.map((t) => t.id), 'request IDs');
    unique(_activities.map((a) => a.id), 'activity IDs');
    unique(
      _units.map((u) => '${u.propertyId}:${u.code.trim().toLowerCase()}'),
      'unit codes within a property',
    );
    unique(
      _invoices.map((i) => '${i.leaseId}:${i.period}'),
      'lease billing periods',
    );
    for (final p in _properties) {
      if (p.name.trim().isEmpty ||
          p.address.trim().isEmpty ||
          !['residence', 'apartment', 'studio'].contains(p.image)) {
        throw const FormatException(
          'Check the property name, address, and cover.',
        );
      }
    }
    for (final u in _units) {
      property(u.propertyId);
      if (u.code.trim().isEmpty ||
          u.capacity < 1 ||
          u.capacity > 20 ||
          u.rent <= 0) {
        throw const FormatException(
          'A unit needs a code, positive rent, and capacity from 1 to 20.',
        );
      }
    }
    for (final t in _tenants) {
      if (t.name.trim().isEmpty) {
        throw const FormatException('A tenant name is required.');
      }
    }
    for (final l in _leases) {
      final u = unit(l.unitId);
      for (final id in l.tenantIds) {
        tenant(id);
      }
      if (l.tenantIds.isEmpty ||
          l.tenantIds.toSet().length != l.tenantIds.length ||
          l.tenantIds.length > u.capacity) {
        throw const FormatException(
          'Lease participants must fit the unit capacity.',
        );
      }
      if (l.end.isBefore(l.start) ||
          l.rent <= 0 ||
          l.deposit < 0 ||
          l.dueDay < 1 ||
          l.dueDay > 31) {
        throw const FormatException(
          'Check the lease dates, rent, deposit, and due day.',
        );
      }
      if (!l.ended &&
          (property(u.propertyId).archived ||
              l.tenantIds.any((id) => tenant(id).archived))) {
        throw const FormatException('A lease cannot use archived records.');
      }
      if (!l.ended) {
        for (final other in _leases) {
          if (other.id != l.id &&
              !other.ended &&
              other.unitId == l.unitId &&
              overlaps(l.start, l.end, other.start, other.end)) {
            throw const FormatException(
              'This unit already has a lease within those dates.',
            );
          }
        }
      }
    }
    for (final i in _invoices) {
      lease(i.leaseId);
      if (i.amount <= 0 ||
          !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(i.period)) {
        throw const FormatException(
          'Invalid invoice amount or billing period.',
        );
      }
    }
    for (final t in _tickets) {
      unit(t.unitId);
      if (t.title.trim().isEmpty ||
          !['Open', 'In progress', 'Resolved'].contains(t.status) ||
          !['Low', 'Normal', 'Urgent'].contains(t.priority)) {
        throw const FormatException('Invalid maintenance request.');
      }
    }
  }

  Future<void> saveProperty(RentalProperty value) async {
    if (isRemote) {
      final body = value.toJson();
      final exists = properties.any((v) => v.id == value.id);
      await _writeRemote(
        exists ? 'PUT' : 'POST',
        exists ? '/properties/${value.id}' : '/properties',
        body,
      );
      return;
    }
    await _mutate(() {
      final index = _properties.indexWhere((p) => p.id == value.id);
      if (value.archived &&
          _leases.any(
            (l) =>
                unit(l.unitId).propertyId == value.id &&
                !l.ended &&
                !l.end.isBefore(today),
          )) {
        throw const FormatException(
          'End current and upcoming leases before archiving this property.',
        );
      }
      if (index < 0) {
        _properties.add(value);
      } else {
        _properties[index] = value;
      }
      _event(
        index < 0
            ? 'Property added'
            : value.archived
            ? 'Property archived'
            : 'Property updated',
        value.name,
        'property',
      );
    });
  }

  Future<void> saveUnit(RentalUnit value) async {
    if (isRemote) {
      final body = value.toJson();
      final exists = units.any((v) => v.id == value.id);
      await _writeRemote(
        exists ? 'PUT' : 'POST',
        exists ? '/units/${value.id}' : '/units',
        body,
      );
      return;
    }
    await _mutate(() {
      if (property(value.propertyId).archived) {
        throw const FormatException(
          'Restore the property before adding units.',
        );
      }
      final index = _units.indexWhere((u) => u.id == value.id);
      if (value.maintenance &&
          _leases.any(
            (l) => l.unitId == value.id && !l.ended && !l.end.isBefore(today),
          )) {
        throw const FormatException(
          'An occupied or reserved unit cannot be taken out of service.',
        );
      }
      if (index < 0) {
        _units.add(value);
      } else {
        _units[index] = value;
      }
      _event(
        index < 0 ? 'Unit added' : 'Unit updated',
        unitLabel(value.id),
        'property',
      );
    });
  }

  Future<void> saveTenant(Tenant value) async {
    if (isRemote) {
      final body = value.toJson();
      final exists = tenants.any((v) => v.id == value.id);
      await _writeRemote(
        exists ? 'PUT' : 'POST',
        exists ? '/tenants/${value.id}' : '/tenants',
        body,
      );
      return;
    }
    await _mutate(() {
      if (value.email.isNotEmpty &&
          _tenants.any(
            (t) =>
                t.id != value.id &&
                !t.archived &&
                t.email.toLowerCase() == value.email.toLowerCase(),
          )) {
        throw const FormatException('A tenant with this email already exists.');
      }
      if (value.archived &&
          _leases.any(
            (l) =>
                l.tenantIds.contains(value.id) &&
                !l.ended &&
                !l.end.isBefore(today),
          )) {
        throw const FormatException(
          'End current and upcoming leases before archiving this tenant.',
        );
      }
      final index = _tenants.indexWhere((t) => t.id == value.id);
      if (index < 0) {
        _tenants.add(value);
      } else {
        _tenants[index] = value;
      }
      _event(
        index < 0
            ? 'Tenant added'
            : value.archived
            ? 'Tenant archived'
            : 'Tenant updated',
        value.name,
        'tenant',
      );
    });
  }

  Json _leaseBody(Lease value) {
    final body = value.toJson()
      ..remove('ended')
      ..remove('cancelled')
      ..remove('revision')
      ..remove('occupancyEnd')
      ..remove('draft');
    body['status'] = value.draft ? 'draft' : 'active';
    body['start'] = value.start.toIso8601String().substring(0, 10);
    body['end'] = value.end.toIso8601String().substring(0, 10);
    return body;
  }

  Future<void> renewLease(Lease value, String parentId) async {
    await _writeRemote('POST', '/leases/$parentId/renew', _leaseBody(value));
  }

  Future<void> addLease(Lease value) async {
    if (isRemote) {
      await _writeRemote('POST', '/leases', _leaseBody(value));
      return;
    }
    await _mutate(() {
      if (unit(value.unitId).maintenance) {
        throw const FormatException(
          'This unit is currently under maintenance.',
        );
      }
      _leases.add(value);
      _event(
        'Lease created',
        '${leaseNames(value)} · ${unitLabel(value.unitId)}',
        'lease',
      );
    });
  }

  Future<void> endLease(String id) async {
    if (isRemote) {
      await _writeRemote('POST', '/leases/$id/end', {
        'revision': lease(id).revision,
      });
      return;
    }
    await _mutate(() {
      final old = lease(id);
      if (old.ended) {
        throw const FormatException('This lease has already ended.');
      }
      _leases[_leases.indexOf(old)] = Lease(
        id: old.id,
        unitId: old.unitId,
        tenantIds: old.tenantIds,
        start: old.start,
        end: today.isBefore(old.start)
            ? old.end
            : today.isBefore(old.end)
            ? today
            : old.end,
        rent: old.rent,
        dueDay: old.dueDay,
        deposit: old.deposit,
        ended: true,
        cancelled: today.isBefore(old.start),
      );
      _event(
        'Lease ended',
        '${leaseNames(old)} · ${unitLabel(old.unitId)}. Existing invoices preserved.',
        'lease',
      );
    });
  }

  Future<int> generateInvoices(DateTime period) async {
    if (isRemote) {
      final response = await _writeRemote('POST', '/invoices/generate', {
        'period': periodKey(period),
      });
      return response['data']['created'] as int;
    }
    var created = 0;
    await _mutate(() {
      final start = DateTime(period.year, period.month),
          end = DateTime(period.year, period.month + 1, 0);
      if (start.isAfter(DateTime(today.year, today.month))) {
        throw const FormatException(
          'Future billing is not enabled. Choose the current or an earlier month.',
        );
      }
      for (final l in _leases) {
        if (l.ended || !overlaps(l.start, l.end, start, end)) continue;
        if (_invoices.any(
          (i) => i.leaseId == l.id && i.period == periodKey(start),
        )) {
          continue;
        }
        // Visible demo policy: full month, no automatic proration or late fees.
        _invoices.add(
          RentInvoice(
            id: newId('invoice'),
            number:
                'INV-${start.year}-${(_invoices.length + 1).toString().padLeft(4, '0')}',
            leaseId: l.id,
            period: periodKey(start),
            due: billingDueDate(start, l.dueDay),
            amount: l.rent,
          ),
        );
        created++;
      }
      if (created > 0) {
        _event(
          'Rent invoices generated',
          '$created invoices · ${monthLabel(start)}',
          'invoice',
        );
      }
    });
    return created;
  }

  Future<void> saveTicket(MaintenanceTicket value) async {
    if (isRemote) {
      final body = value.toJson()
        ..remove('created')
        ..remove('history');
      final exists = tickets.any((v) => v.id == value.id);
      await _writeRemote(
        exists ? 'PUT' : 'POST',
        exists ? '/tickets/${value.id}' : '/tickets',
        body,
      );
      return;
    }
    await _mutate(() {
      final index = _tickets.indexWhere((t) => t.id == value.id);
      if (index < 0) {
        _tickets.add(value);
      } else {
        _tickets[index] = value;
      }
      _event(
        index < 0
            ? 'Maintenance request opened'
            : 'Maintenance request updated',
        '${value.title} · ${unitLabel(value.unitId)}',
        'maintenance',
      );
    });
  }

  Future<void> updateTicketStatus(String id, String status) {
    final old = _tickets.firstWhere((t) => t.id == id);
    return saveTicket(
      MaintenanceTicket(
        id: old.id,
        revision: old.revision,
        unitId: old.unitId,
        title: old.title,
        description: old.description,
        category: old.category,
        priority: old.priority,
        status: status,
        created: old.created,
        history: [
          ...old.history,
          '${shortDate(today)} · $status by $ownerName',
        ],
      ),
    );
  }

  Future<void> updateProfile({
    required String name,
    required String email,
    required String organization,
    int? expectedRevision,
  }) async {
    if (isRemote) {
      await _writeRemote('PUT', '/profile', {
        'name': name.trim(),
        'email': email.trim(),
        'organization': organization.trim(),
        'revision': expectedRevision ?? revision,
      });
      return;
    }
    await _mutate(() {
      ownerName = name.trim();
      ownerEmail = email.trim();
      organizationName = organization.trim();
      _event('Workspace updated', organizationName, 'settings');
    });
  }

  Future<void> importJson(String raw) => _mutate(() {
    if (isRemote) {
      throw const FormatException(
        'Database restore is only available through the development tools.',
      );
    }
    _read(jsonDecode(raw) as Json);
    _event('Workspace imported', 'Restored from a local export', 'settings');
  });
  Future<void> resetDemo() => _mutate(() {
    if (isRemote) {
      throw const FormatException(
        'Use the backend seed command to add development sample data.',
      );
    }
    _seed();
  });
  Future<void> clearWorkspace() => _mutate(() {
    if (isRemote) {
      throw const FormatException(
        'Deleting the database from the app is disabled.',
      );
    }
    _properties = [];
    _units = [];
    _tenants = [];
    _leases = [];
    _invoices = [];
    _tickets = [];
    _activities = [];
    _event(
      'A fresh start',
      'Your workspace is ready for your first property.',
      'settings',
    );
  });

  void _seed() {
    ownerName = 'Alex Santos';
    ownerEmail = 'alex@example.com';
    organizationName = 'Kwadra Living';
    _properties = [
      const RentalProperty(
        id: 'p-1',
        name: 'The Palm Residences',
        address: 'Lahug, Cebu City',
        type: 'Apartment',
        image: 'residence',
        notes: 'A quiet address with room to grow. Near IT Park, cafés, and everyday essentials.',
      ),
      const RentalProperty(
        id: 'p-2',
        name: 'Casa Verde Apartments',
        address: 'Banilad, Mandaue City',
        type: 'Apartment',
        image: 'apartment',
        notes: 'Light-filled homes in a friendly neighborhood. Parking available for residents.',
      ),
      const RentalProperty(
        id: 'p-3',
        name: 'Sundown Studios',
        address: 'Guadalupe, Cebu City',
        type: 'Boarding house',
        image: 'studio',
        notes: 'Thoughtfully furnished studios for students and young professionals.',
      ),
    ];
    _units = [];
    for (var p = 1; p <= 3; p++) {
      for (var n = 1; n <= 8; n++) {
        _units.add(
          RentalUnit(
            id: 'u-$p-$n',
            propertyId: 'p-$p',
            code:
                '${p == 3
                    ? 'S'
                    : p == 2
                    ? 'B'
                    : 'A'}-${n.toString().padLeft(2, '0')}',
            type: p == 3
                ? 'Studio'
                : n.isEven
                ? '1 Bedroom'
                : 'Studio',
            rent:
                (p == 1
                    ? 9500
                    : p == 2
                    ? 8500
                    : 6000) *
                100,
            capacity: 2,
            floor: n <= 4 ? 'Ground floor' : '2nd floor',
            maintenance: p == 2 && n == 8,
          ),
        );
      }
    }
    const names = [
      'Isabel Reyes',
      'Miguel Cruz',
      'Sofia Garcia',
      'Daniel Lim',
      'Andrea Flores',
      'Paolo Mendoza',
      'Camille Tan',
      'Rafael Ramos',
      'Bianca Santos',
      'Luis Navarro',
      'Nicole Villanueva',
      'Marco Bautista',
      'Julia Torres',
      'Adrian Dela Cruz',
      'Chloe Castillo',
      'Gabriel Uy',
      'Alyssa Rivera',
      'Joshua Lopez',
    ];
    _tenants = List.generate(
      names.length,
      (i) => Tenant(
        id: 't-$i',
        name: names[i],
        email: '${names[i].toLowerCase().replaceAll(' ', '.')}@example.com',
        phone: '0917 555 ${(1000 + i).toString()}',
        emergency: 'Family contact · 0918 555 0100',
      ),
    );
    _leases = [];
    _invoices = [];
    for (var i = 0; i < names.length; i++) {
      final u = unit('u-${i ~/ 6 + 1}-${i % 6 + 1}');
      final l = Lease(
        id: 'l-$i',
        unitId: u.id,
        tenantIds: ['t-$i'],
        start: DateTime(today.year, today.month - (i % 5 + 1), 1),
        end: DateTime(today.year + 1, today.month - (i % 5 + 1), 0),
        rent: u.rent,
        dueDay: i.isEven ? 5 : 20,
        deposit: u.rent * 2,
      );
      _leases.add(l);
      _invoices.add(
        RentInvoice(
          id: 'i-$i',
          number: 'INV-${today.year}-${(i + 1).toString().padLeft(4, '0')}',
          leaseId: l.id,
          period: periodKey(today),
          due: billingDueDate(today, l.dueDay),
          amount: l.rent,
        ),
      );
    }
    _tickets = [
      MaintenanceTicket(
        id: 'm-1',
        unitId: 'u-1-3',
        title: 'Kitchen faucet needs a little care',
        description: 'A slow leak under the kitchen sink. Please check the connector and replace the washer if needed.',
        category: 'Plumbing',
        priority: 'Urgent',
        status: 'Open',
        created: today.subtract(const Duration(days: 1)),
        history: ['Request created by Sofia Garcia'],
      ),
      MaintenanceTicket(
        id: 'm-2',
        unitId: 'u-2-2',
        title: 'Air conditioner is not cooling',
        description: 'The unit turns on but is no longer cooling the room. Filter cleaning may be needed.',
        category: 'Appliance',
        priority: 'Normal',
        status: 'In progress',
        created: today.subtract(const Duration(days: 2)),
        history: [
          'Request created by Rafael Ramos',
          'Technician visit arranged',
        ],
      ),
      MaintenanceTicket(
        id: 'm-3',
        unitId: 'u-3-4',
        title: 'Hallway light replacement',
        description: 'The light outside the studio is flickering. A replacement bulb is needed.',
        category: 'Electrical',
        priority: 'Low',
        status: 'Open',
        created: today.subtract(const Duration(days: 3)),
        history: ['Request created by Gabriel Uy'],
      ),
      MaintenanceTicket(
        id: 'm-4',
        unitId: 'u-2-8',
        title: 'Fresh paint before move-in',
        description: 'Refresh the bedroom walls and inspect the door hinges before making the unit available.',
        category: 'General',
        priority: 'Normal',
        status: 'In progress',
        created: today.subtract(const Duration(days: 4)),
        history: ['Request created by Alex Santos'],
      ),
      MaintenanceTicket(
        id: 'm-5',
        unitId: 'u-1-1',
        title: 'Bathroom door handle repaired',
        description: 'Loose handle secured and tested.',
        category: 'General',
        priority: 'Low',
        status: 'Resolved',
        created: today.subtract(const Duration(days: 7)),
        history: ['Request created', 'Resolved after replacing screws'],
      ),
    ];
    _activities = [
      ActivityEvent(
        id: 'a-1',
        title: 'Your workspace is ready',
        detail: 'Three properties, one connected portfolio.',
        created: today.subtract(const Duration(days: 3)),
        kind: 'property',
      ),
      ActivityEvent(
        id: 'a-2',
        title: 'Rent invoices generated',
        detail: '18 invoices · ${monthLabel(today)}',
        created: today.subtract(const Duration(days: 2)),
        kind: 'invoice',
      ),
      ActivityEvent(
        id: 'a-3',
        title: 'Maintenance request opened',
        detail: 'Kitchen faucet · The Palm Residences, A-03',
        created: today.subtract(const Duration(hours: 18)),
        kind: 'maintenance',
      ),
      ActivityEvent(
        id: 'a-4',
        title: 'A home, ready for someone new',
        detail: 'Sundown Studios · S-07 is available',
        created: today.subtract(const Duration(hours: 3)),
        kind: 'property',
      ),
    ];
    _validate();
  }
}
