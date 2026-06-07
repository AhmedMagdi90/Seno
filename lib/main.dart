import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  runApp(SenoApp(store: store));
}

const productStatuses = [
  'Pending reservation',
  'Reservation sent',
  'Office confirmed',
  'Unavailable',
  'Ready for pickup',
  'With delivery',
  'Delivered',
  'Cancelled',
];

const orderStatuses = [
  'New',
  'Waiting office confirmation',
  'Confirmed',
  'Ready',
  'Out for delivery',
  'Customer received',
  'Closed',
  'Cancelled',
];

const shareChannel = MethodChannel('app.seno.seller/share');

class SenoApp extends StatelessWidget {
  const SenoApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFF0F766E);
    return StoreScope(
      store: store,
      child: MaterialApp(
        title: 'Seno',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: brand,
            primary: brand,
            secondary: const Color(0xFFF59E0B),
            surface: const Color(0xFFFAFAF7),
          ),
          scaffoldBackgroundColor: const Color(0xFFF7F7F2),
          fontFamily: 'Arial',
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF7F7F2),
            foregroundColor: Color(0xFF111827),
            elevation: 0,
            centerTitle: false,
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            filled: true,
            fillColor: Colors.white,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        home: const HomeShell(),
      ),
    );
  }
}

class StoreScope extends InheritedNotifier<AppStore> {
  const StoreScope({super.key, required AppStore store, required super.child})
    : super(notifier: store);

  static AppStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StoreScope>();
    if (scope == null || scope.notifier == null) {
      throw StateError('StoreScope is missing');
    }
    return scope.notifier!;
  }
}

class AppStore extends ChangeNotifier {
  static const _storageKey = 'seno_state_v1';
  final List<SenoOrder> orders = [];
  final List<Office> offices = [];
  final List<ReservationBatch> reservationBatches = [];
  String deliveryPhone = '';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      offices
        ..clear()
        ..addAll(
          (payload['offices'] as List<dynamic>).map(
            (item) => Office.fromJson(item as Map<String, dynamic>),
          ),
        );
      orders
        ..clear()
        ..addAll(
          (payload['orders'] as List<dynamic>).map(
            (item) => SenoOrder.fromJson(item as Map<String, dynamic>),
          ),
        );
      reservationBatches
        ..clear()
        ..addAll(
          (payload['reservationBatches'] as List<dynamic>? ?? []).map(
            (item) => ReservationBatch.fromJson(item as Map<String, dynamic>),
          ),
        );
      deliveryPhone = payload['deliveryPhone'] as String? ?? '';
    }
    if (offices.isEmpty) {
      offices.addAll([
        Office(
          id: newId(),
          name: 'Main Office',
          phone: '',
          notes: 'Default supplier office',
        ),
        Office(
          id: newId(),
          name: 'Second Office',
          phone: '',
          notes: 'Backup supplier office',
        ),
      ]);
      await save();
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode({
        'offices': offices.map((office) => office.toJson()).toList(),
        'orders': orders.map((order) => order.toJson()).toList(),
        'reservationBatches': reservationBatches
            .map((batch) => batch.toJson())
            .toList(),
        'deliveryPhone': deliveryPhone,
      }),
    );
  }

  Future<void> addOffice(Office office) async {
    offices.add(office);
    await saveAndNotify();
  }

  Future<void> updateOffice(Office office) async {
    final index = offices.indexWhere((item) => item.id == office.id);
    if (index >= 0) {
      offices[index] = office;
      await saveAndNotify();
    }
  }

  Future<void> addOrder(SenoOrder order) async {
    orders.insert(0, order);
    await saveAndNotify();
  }

  Future<void> updateOrder(SenoOrder order) async {
    final index = orders.indexWhere((item) => item.id == order.id);
    if (index >= 0) {
      orders[index] = order;
      await saveAndNotify();
    }
  }

  Future<ReservationBatch> markOfficeReservationSent(
    String officeId,
    List<OrderItemMatch> matches,
    String message,
  ) async {
    final batch = ReservationBatch(
      id: newId(),
      officeId: officeId,
      itemIds: matches.map((match) => match.item.id).toList(),
      sentAt: DateTime.now(),
      message: message,
    );
    reservationBatches.insert(0, batch);
    for (final order in orders) {
      for (final item in order.items) {
        if (item.officeId == officeId && item.status == 'Pending reservation') {
          item.status = 'Reservation sent';
        }
      }
      order.status = order.derivedStatus;
    }
    await saveAndNotify();
    return batch;
  }

  Future<void> updateDeliveryPhone(String phone) async {
    deliveryPhone = phone.trim();
    await saveAndNotify();
  }

  Future<void> clearAll() async {
    orders.clear();
    reservationBatches.clear();
    await saveAndNotify();
  }

  Future<void> saveAndNotify() async {
    await save();
    notifyListeners();
  }

  Office? officeById(String id) {
    for (final office in offices) {
      if (office.id == id) return office;
    }
    return null;
  }

  List<OrderItemMatch> pendingForOffice(String officeId) {
    final matches = <OrderItemMatch>[];
    for (final order in orders) {
      for (final item in order.items) {
        if (item.officeId == officeId && item.status == 'Pending reservation') {
          matches.add(OrderItemMatch(order: order, item: item));
        }
      }
    }
    return matches;
  }

  List<ReservationBatch> batchesForOffice(String officeId) => reservationBatches
      .where((batch) => batch.officeId == officeId)
      .toList(growable: false);

  String exportJson() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'exportedAt': DateTime.now().toIso8601String(),
      'app': 'Seno',
      'offices': offices.map((office) => office.toJson()).toList(),
      'orders': orders.map((order) => order.toJson()).toList(),
      'reservationBatches': reservationBatches
          .map((batch) => batch.toJson())
          .toList(),
      'deliveryPhone': deliveryPhone,
    });
  }

  double get totalSales => orders.fold(0, (sum, order) => sum + order.total);
  double get totalCost => orders.fold(0, (sum, order) => sum + order.cost);
  double get totalPaid =>
      orders.fold(0, (sum, order) => sum + order.paidAmount);
  double get totalProfit => orders.fold(0, (sum, order) => sum + order.profit);
  double get totalRemaining =>
      orders.fold(0, (sum, order) => sum + order.remaining);
}

class Office {
  Office({
    required this.id,
    required this.name,
    required this.phone,
    this.notes = '',
  });

  final String id;
  final String name;
  final String phone;
  final String notes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'notes': notes,
  };

  factory Office.fromJson(Map<String, dynamic> json) => Office(
    id: json['id'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
  );
}

class SenoOrder {
  SenoOrder({
    required this.id,
    required this.customerName,
    required this.phone,
    required this.receiptMethod,
    required this.address,
    required this.notes,
    required this.status,
    required this.paidAmount,
    required this.createdAt,
    required this.items,
    List<PaymentRecord>? payments,
  }) : payments =
           payments ??
           (paidAmount > 0
               ? [
                   PaymentRecord(
                     id: newId(),
                     amount: paidAmount,
                     paidAt: createdAt,
                     note: 'Initial paid amount',
                   ),
                 ]
               : []);

  final String id;
  String customerName;
  String phone;
  String receiptMethod;
  String address;
  String notes;
  String status;
  double paidAmount;
  DateTime createdAt;
  final List<SenoOrderItem> items;
  final List<PaymentRecord> payments;

  double get total => items.fold(0, (sum, item) => sum + item.customerPrice);
  double get cost => items.fold(0, (sum, item) => sum + item.originPrice);
  double get profit => total - cost;
  double get remaining => total - paidAmount;

  String get derivedStatus {
    if (items.isEmpty) return status;
    if (items.every((item) => item.status == 'Cancelled')) return 'Cancelled';
    if (items.every((item) => item.status == 'Delivered')) {
      return paidAmount >= total ? 'Closed' : 'Customer received';
    }
    if (items.any((item) => item.status == 'With delivery')) {
      return 'Out for delivery';
    }
    if (items.every((item) => item.status == 'Ready for pickup')) {
      return 'Ready';
    }
    if (items.every(
      (item) =>
          item.status == 'Office confirmed' ||
          item.status == 'Ready for pickup' ||
          item.status == 'Delivered',
    )) {
      return 'Confirmed';
    }
    if (items.any((item) => item.status == 'Reservation sent')) {
      return 'Waiting office confirmation';
    }
    return status;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'customerName': customerName,
    'phone': phone,
    'receiptMethod': receiptMethod,
    'address': address,
    'notes': notes,
    'status': status,
    'paidAmount': paidAmount,
    'createdAt': createdAt.toIso8601String(),
    'items': items.map((item) => item.toJson()).toList(),
    'payments': payments.map((payment) => payment.toJson()).toList(),
  };

  factory SenoOrder.fromJson(Map<String, dynamic> json) => SenoOrder(
    id: json['id'] as String,
    customerName: json['customerName'] as String,
    phone: json['phone'] as String? ?? '',
    receiptMethod: json['receiptMethod'] as String? ?? 'Shipment',
    address: json['address'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
    status: json['status'] as String? ?? 'New',
    paidAmount: (json['paidAmount'] as num?)?.toDouble() ?? 0,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    items: (json['items'] as List<dynamic>? ?? [])
        .map((item) => SenoOrderItem.fromJson(item as Map<String, dynamic>))
        .toList(),
    payments: (json['payments'] as List<dynamic>? ?? [])
        .map((item) => PaymentRecord.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class PaymentRecord {
  PaymentRecord({
    required this.id,
    required this.amount,
    required this.paidAt,
    this.note = '',
  });

  final String id;
  final double amount;
  final DateTime paidAt;
  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'paidAt': paidAt.toIso8601String(),
    'note': note,
  };

  factory PaymentRecord.fromJson(Map<String, dynamic> json) => PaymentRecord(
    id: json['id'] as String,
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    paidAt:
        DateTime.tryParse(json['paidAt'] as String? ?? '') ?? DateTime.now(),
    note: json['note'] as String? ?? '',
  );
}

class ReservationBatch {
  ReservationBatch({
    required this.id,
    required this.officeId,
    required this.itemIds,
    required this.sentAt,
    required this.message,
  });

  final String id;
  final String officeId;
  final List<String> itemIds;
  final DateTime sentAt;
  final String message;

  Map<String, dynamic> toJson() => {
    'id': id,
    'officeId': officeId,
    'itemIds': itemIds,
    'sentAt': sentAt.toIso8601String(),
    'message': message,
  };

  factory ReservationBatch.fromJson(Map<String, dynamic> json) =>
      ReservationBatch(
        id: json['id'] as String,
        officeId: json['officeId'] as String? ?? '',
        itemIds: (json['itemIds'] as List<dynamic>? ?? [])
            .map((item) => item.toString())
            .toList(),
        sentAt:
            DateTime.tryParse(json['sentAt'] as String? ?? '') ??
            DateTime.now(),
        message: json['message'] as String? ?? '',
      );
}

class SenoOrderItem {
  SenoOrderItem({
    required this.id,
    required this.productName,
    required this.photoPath,
    required this.officeId,
    required this.originPrice,
    required this.customerPrice,
    required this.status,
    this.notes = '',
  });

  final String id;
  String productName;
  String photoPath;
  String officeId;
  double originPrice;
  double customerPrice;
  String status;
  String notes;

  double get profit => customerPrice - originPrice;

  Map<String, dynamic> toJson() => {
    'id': id,
    'productName': productName,
    'photoPath': photoPath,
    'officeId': officeId,
    'originPrice': originPrice,
    'customerPrice': customerPrice,
    'status': status,
    'notes': notes,
  };

  factory SenoOrderItem.fromJson(Map<String, dynamic> json) => SenoOrderItem(
    id: json['id'] as String,
    productName: json['productName'] as String? ?? 'Product',
    photoPath: json['photoPath'] as String? ?? '',
    officeId: json['officeId'] as String? ?? '',
    originPrice: (json['originPrice'] as num?)?.toDouble() ?? 0,
    customerPrice: (json['customerPrice'] as num?)?.toDouble() ?? 0,
    status: json['status'] as String? ?? 'Pending reservation',
    notes: json['notes'] as String? ?? '',
  );
}

class OrderItemMatch {
  OrderItemMatch({required this.order, required this.item});

  final SenoOrder order;
  final SenoOrderItem item;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    shareChannel.setMethodCallHandler((call) async {
      if (call.method != 'sharedImageReceived') return;
      final path = call.arguments as String?;
      if (!mounted || path == null || path.isEmpty) return;
      await openNewOrder(context, initialPhotoPath: path);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSharedPhoto());
  }

  Future<void> _openSharedPhoto() async {
    final path = await takeSharedPhotoPath();
    if (!mounted || path == null || path.isEmpty) return;
    await openNewOrder(context, initialPhotoPath: path);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const DashboardScreen(),
      const OrdersScreen(),
      const OfficesScreen(),
      const FinanceScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: screens[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Orders',
          ),
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Offices',
          ),
          NavigationDestination(
            icon: Icon(Icons.payments_outlined),
            selectedIcon: Icon(Icons.payments),
            label: 'Finance',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final pendingCount = store.orders
        .expand((order) => order.items)
        .where((item) => item.status == 'Pending reservation')
        .length;
    final deliveryCount = store.orders
        .where(
          (order) =>
              order.status == 'Out for delivery' ||
              order.items.any((item) => item.status == 'With delivery'),
        )
        .length;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Row(
              children: [SenoLogo(size: 44), SizedBox(width: 12), Text('Seno')],
            ),
            actions: [
              IconButton(
                tooltip: 'New order',
                onPressed: () => openNewOrder(context),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Today workflow',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Orders',
                      value: store.orders.length.toString(),
                      icon: Icons.receipt_long,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Pending',
                      value: pendingCount.toString(),
                      icon: Icons.pending_actions,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Delivery',
                      value: deliveryCount.toString(),
                      icon: Icons.local_shipping,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Profit',
                      value: money(store.totalProfit),
                      icon: Icons.trending_up,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => openNewOrder(context),
                icon: const Icon(Icons.add),
                label: const Text('Create order'),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                title: 'Needs action',
                action: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OfficesScreen()),
                  ),
                  icon: const Icon(Icons.storefront),
                  label: const Text('Offices'),
                ),
              ),
              if (store.orders.isEmpty)
                const EmptyState(
                  icon: Icons.shopping_bag_outlined,
                  title: 'No orders yet',
                  body: 'Create the first customer order to start tracking.',
                )
              else
                ...store.orders.take(4).map((order) => OrderCard(order: order)),
            ],
          ),
        );
      },
    );
  }
}

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String _query = '';
  String _status = 'All';

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final filtered = store.orders.where((order) {
          final query = _query.trim().toLowerCase();
          final matchesQuery =
              query.isEmpty ||
              order.customerName.toLowerCase().contains(query) ||
              order.phone.toLowerCase().contains(query);
          final matchesStatus = _status == 'All' || order.status == _status;
          return matchesQuery && matchesStatus;
        }).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Orders'),
            actions: [
              IconButton(
                tooltip: 'New order',
                onPressed: () => openNewOrder(context),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search customer or phone',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Order status'),
                items: ['All', ...orderStatuses]
                    .map(
                      (status) =>
                          DropdownMenuItem(value: status, child: Text(status)),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _status = value ?? 'All'),
              ),
              const SizedBox(height: 16),
              if (filtered.isEmpty)
                const EmptyState(
                  icon: Icons.manage_search,
                  title: 'No matching orders',
                  body: 'Try another customer name, phone, or status.',
                )
              else
                ...filtered.map((order) => OrderCard(order: order)),
            ],
          ),
        );
      },
    );
  }
}

class OfficesScreen extends StatelessWidget {
  const OfficesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Offices'),
            actions: [
              IconButton(
                tooltip: 'Add office',
                onPressed: () => showOfficeForm(context),
                icon: const Icon(Icons.add_business),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FilledButton.icon(
                onPressed: () => showOfficeForm(context),
                icon: const Icon(Icons.add),
                label: const Text('Add office'),
              ),
              const SizedBox(height: 16),
              if (store.offices.isEmpty)
                const EmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'No offices',
                  body: 'Add the offices you reserve products from.',
                )
              else
                ...store.offices.map((office) {
                  final pending = store.pendingForOffice(office.id);
                  final batches = store.batchesForOffice(office.id);
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.storefront),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  office.name,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                              StatusPill(label: '${pending.length} pending'),
                            ],
                          ),
                          if (office.phone.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(office.phone),
                          ],
                          if (office.notes.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              office.notes,
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: pending.isEmpty
                                    ? null
                                    : () => sendOfficeReservation(
                                        context,
                                        office,
                                        pending,
                                      ),
                                icon: const Icon(Icons.send),
                                label: const Text('Reserve all pending'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    showOfficeForm(context, office: office),
                                icon: const Icon(Icons.edit_outlined),
                                label: const Text('Edit'),
                              ),
                            ],
                          ),
                          if (pending.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            ...pending
                                .take(3)
                                .map(
                                  (match) => Text(
                                    '- ${match.item.productName} for ${match.order.customerName}',
                                  ),
                                ),
                          ],
                          if (batches.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Divider(),
                            Text(
                              'Last reservation: ${shortDate(batches.first.sentAt)} | ${batches.first.itemIds.length} products',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  showReservationHistory(context, office),
                              icon: const Icon(Icons.history),
                              label: const Text('Reservation history'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}

class FinanceScreen extends StatelessWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Finance')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Sales',
                      value: money(store.totalSales),
                      icon: Icons.sell,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Cost',
                      value: money(store.totalCost),
                      icon: Icons.inventory_2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Paid',
                      value: money(store.totalPaid),
                      icon: Icons.account_balance_wallet,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Remaining',
                      value: money(store.totalRemaining),
                      icon: Icons.warning_amber,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              MetricCard(
                title: 'Income / Profit',
                value: money(store.totalProfit),
                icon: Icons.trending_up,
              ),
              const SizedBox(height: 20),
              SectionHeader(title: 'Order totals'),
              if (store.orders.isEmpty)
                const EmptyState(
                  icon: Icons.payments_outlined,
                  title: 'No finance data',
                  body: 'Orders and payments will appear here.',
                )
              else
                ...store.orders.map(
                  (order) => Card(
                    child: ListTile(
                      title: Text(order.customerName),
                      subtitle: Text(
                        'Total ${money(order.total)} | Paid ${money(order.paidAmount)} | Profit ${money(order.profit)}',
                      ),
                      trailing: Text(money(order.remaining)),
                      onTap: () => openOrderDetails(context, order),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const SenoLogo(size: 72),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Seno',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const Text('Seller orders and office reservations'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SectionHeader(title: 'MVP features'),
              const FeatureRow(
                icon: Icons.photo_camera_outlined,
                title: 'Product photos',
                body: 'Add product images from camera or gallery.',
              ),
              const FeatureRow(
                icon: Icons.storefront_outlined,
                title: 'Office reservations',
                body: 'Send pending products to the right office.',
              ),
              const FeatureRow(
                icon: Icons.chat_outlined,
                title: 'WhatsApp handoff',
                body: 'Prepare reservation and delivery messages.',
              ),
              const FeatureRow(
                icon: Icons.payments_outlined,
                title: 'Profit tracking',
                body:
                    'Track origin price, customer price, paid, and remaining.',
              ),
              const SizedBox(height: 20),
              SectionHeader(title: 'Operations'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.local_shipping_outlined),
                  title: const Text('Delivery WhatsApp'),
                  subtitle: Text(
                    store.deliveryPhone.isEmpty
                        ? 'Not set'
                        : store.deliveryPhone,
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => showDeliverySettings(context),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Export backup'),
                  subtitle: const Text(
                    'Copy all orders, offices, payments, and reservations as JSON.',
                  ),
                  trailing: const Icon(Icons.copy),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: store.exportJson()),
                    );
                    if (context.mounted) {
                      showSnack(context, 'Backup JSON copied.');
                    }
                  },
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: store.orders.isEmpty
                    ? null
                    : () async {
                        final confirmed = await confirm(
                          context,
                          'Clear orders?',
                          'This removes local orders from the MVP app. Offices stay saved.',
                        );
                        if (confirmed) {
                          await store.clearAll();
                        }
                      },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear local orders'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class NewOrderScreen extends StatefulWidget {
  const NewOrderScreen({super.key, this.initialPhotoPath = ''});

  final String initialPhotoPath;

  @override
  State<NewOrderScreen> createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends State<NewOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _customer = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _notes = TextEditingController();
  final _paid = TextEditingController(text: '0');
  late final List<DraftItem> _draftItems;
  String _receiptMethod = 'Shipment';

  @override
  void initState() {
    super.initState();
    _draftItems = [DraftItem(photoPath: widget.initialPhotoPath)];
  }

  @override
  void dispose() {
    _customer.dispose();
    _phone.dispose();
    _address.dispose();
    _notes.dispose();
    _paid.dispose();
    for (final item in _draftItems) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New order')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionHeader(title: 'Customer'),
            TextFormField(
              controller: _customer,
              decoration: const InputDecoration(labelText: 'Customer name'),
              validator: requiredText,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'Shipment',
                  label: Text('Shipment'),
                  icon: Icon(Icons.local_shipping_outlined),
                ),
                ButtonSegment(
                  value: 'Pickup',
                  label: Text('Pickup'),
                  icon: Icon(Icons.store_outlined),
                ),
              ],
              selected: {_receiptMethod},
              onSelectionChanged: (value) =>
                  setState(() => _receiptMethod = value.first),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _address,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Address details'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Order notes'),
            ),
            const SizedBox(height: 20),
            SectionHeader(
              title: 'Products',
              action: TextButton.icon(
                onPressed: () => setState(() => _draftItems.add(DraftItem())),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ),
            ..._draftItems.asMap().entries.map(
              (entry) => DraftProductCard(
                index: entry.key,
                draft: entry.value,
                canRemove: _draftItems.length > 1,
                onRemove: () {
                  setState(() {
                    final item = _draftItems.removeAt(entry.key);
                    item.dispose();
                  });
                },
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _paid,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Paid amount'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                if (!_formKey.currentState!.validate()) return;
                if (store.offices.isEmpty) {
                  showSnack(context, 'Add an office first.');
                  return;
                }
                final order = SenoOrder(
                  id: newId(),
                  customerName: _customer.text.trim(),
                  phone: _phone.text.trim(),
                  receiptMethod: _receiptMethod,
                  address: _address.text.trim(),
                  notes: _notes.text.trim(),
                  status: 'New',
                  paidAmount: parseMoney(_paid.text),
                  createdAt: DateTime.now(),
                  items: _draftItems
                      .map(
                        (draft) => SenoOrderItem(
                          id: newId(),
                          productName: draft.name.text.trim().isEmpty
                              ? 'Product'
                              : draft.name.text.trim(),
                          photoPath: draft.photoPath,
                          officeId: draft.officeId ?? store.offices.first.id,
                          originPrice: parseMoney(draft.originPrice.text),
                          customerPrice: parseMoney(draft.customerPrice.text),
                          status: 'Pending reservation',
                          notes: draft.notes.text.trim(),
                        ),
                      )
                      .toList(),
                );
                order.status = order.derivedStatus;
                await store.addOrder(order);
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.save),
              label: const Text('Save order'),
            ),
          ],
        ),
      ),
    );
  }
}

class DraftProductCard extends StatefulWidget {
  const DraftProductCard({
    super.key,
    required this.index,
    required this.draft,
    required this.canRemove,
    required this.onRemove,
  });

  final int index;
  final DraftItem draft;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  State<DraftProductCard> createState() => _DraftProductCardState();
}

class _DraftProductCardState extends State<DraftProductCard> {
  final _picker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final selectedOffice =
        widget.draft.officeId ??
        (store.offices.isNotEmpty ? store.offices.first.id : null);
    widget.draft.officeId = selectedOffice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Product ${widget.index + 1}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (widget.canRemove)
                  IconButton(
                    tooltip: 'Remove product',
                    onPressed: widget.onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ProductPhotoBox(
              path: widget.draft.photoPath,
              onPick: () async {
                final source = await chooseImageSource(context);
                if (source == null) return;
                final picked = await _picker.pickImage(
                  source: source,
                  imageQuality: 78,
                );
                if (picked != null) {
                  setState(() => widget.draft.photoPath = picked.path);
                }
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: widget.draft.name,
              decoration: const InputDecoration(labelText: 'Product name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selectedOffice,
              decoration: const InputDecoration(labelText: 'Office'),
              items: store.offices
                  .map(
                    (office) => DropdownMenuItem(
                      value: office.id,
                      child: Text(office.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => widget.draft.officeId = value),
              validator: (value) => value == null ? 'Select office' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: widget.draft.originPrice,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Origin price',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: widget.draft.customerPrice,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Customer price',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: widget.draft.notes,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Product notes'),
            ),
          ],
        ),
      ),
    );
  }
}

class OrderDetailsScreen extends StatefulWidget {
  const OrderDetailsScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen> {
  final _payment = TextEditingController();

  @override
  void dispose() {
    _payment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final order = store.orders.firstWhere(
          (item) => item.id == widget.orderId,
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(order.customerName),
            actions: [
              IconButton(
                tooltip: 'Edit order',
                onPressed: () => showEditOrderForm(context, order),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              order.customerName,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ),
                          StatusPill(label: order.status),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Phone: ${blank(order.phone)}'),
                      Text('Receive: ${order.receiptMethod}'),
                      Text('Address: ${blank(order.address)}'),
                      if (order.notes.isNotEmpty) Text('Notes: ${order.notes}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Total',
                      value: money(order.total),
                      icon: Icons.sell,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Profit',
                      value: money(order.profit),
                      icon: Icons.trending_up,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetricCard(
                      title: 'Paid',
                      value: money(order.paidAmount),
                      icon: Icons.payments,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MetricCard(
                      title: 'Remaining',
                      value: money(order.remaining),
                      icon: Icons.account_balance_wallet,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SectionHeader(
                title: 'Products',
                action: TextButton.icon(
                  onPressed: () => showEditProductForm(context, order),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ),
              ...order.items.map(
                (item) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ProductThumb(path: item.photoPath),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.productName,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    store.officeById(item.officeId)?.name ??
                                        'No office',
                                  ),
                                  Text(
                                    'Cost ${money(item.originPrice)} | Customer ${money(item.customerPrice)}',
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit product',
                              onPressed: () =>
                                  showEditProductForm(context, order, item),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: item.status,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                          ),
                          items: productStatuses
                              .map(
                                (status) => DropdownMenuItem(
                                  value: status,
                                  child: Text(status),
                                ),
                              )
                              .toList(),
                          onChanged: (value) async {
                            if (value == null) return;
                            item.status = value;
                            order.status = order.derivedStatus;
                            await store.updateOrder(order);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SectionHeader(title: 'Payment'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _payment,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Add paid'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () async {
                      final amount = parseMoney(_payment.text);
                      if (amount <= 0) return;
                      order.paidAmount += amount;
                      order.payments.add(
                        PaymentRecord(
                          id: newId(),
                          amount: amount,
                          paidAt: DateTime.now(),
                          note: 'Manual payment',
                        ),
                      );
                      order.status = order.derivedStatus;
                      _payment.clear();
                      await store.updateOrder(order);
                    },
                    child: const Text('Add'),
                  ),
                ],
              ),
              if (order.payments.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...order.payments.reversed.map(
                  (payment) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.receipt_outlined),
                      title: Text(money(payment.amount)),
                      subtitle: Text(
                        '${shortDate(payment.paidAt)}'
                        '${payment.note.isEmpty ? '' : ' | ${payment.note}'}',
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => sendDeliveryMessage(context, order),
                    icon: const Icon(Icons.chat),
                    label: const Text('Send address WhatsApp'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      for (final item in order.items) {
                        if (item.status != 'Cancelled') {
                          item.status = 'Delivered';
                        }
                      }
                      order.status = order.derivedStatus;
                      await store.updateOrder(order);
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Customer received'),
                  ),
                  OutlinedButton.icon(
                    onPressed: order.paidAmount < order.total
                        ? null
                        : () async {
                            order.status = 'Closed';
                            await store.updateOrder(order);
                          },
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Close order'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class DraftItem {
  DraftItem({this.photoPath = ''});

  final name = TextEditingController();
  final originPrice = TextEditingController();
  final customerPrice = TextEditingController();
  final notes = TextEditingController();
  String? officeId;
  String photoPath;

  void dispose() {
    name.dispose();
    originPrice.dispose();
    customerPrice.dispose();
    notes.dispose();
  }
}

class SenoLogo extends StatelessWidget {
  const SenoLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0F766E),
        borderRadius: BorderRadius.circular(size * 0.18),
      ),
      child: Stack(
        children: [
          Positioned(
            right: size * 0.13,
            bottom: size * 0.13,
            child: Icon(
              Icons.done,
              size: size * 0.34,
              color: const Color(0xFFFBBF24),
            ),
          ),
          Center(
            child: Text(
              'S',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.58,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(color: Colors.grey.shade700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Icon(icon, size: 42, color: Colors.grey.shade600),
            const SizedBox(height: 10),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }
}

class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.order});

  final SenoOrder order;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        title: Text(
          order.customerName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${order.items.length} products | ${money(order.total)} | ${order.receiptMethod}',
        ),
        trailing: StatusPill(label: order.status),
        onTap: () => openOrderDetails(context, order),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE0F2F1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF0F766E),
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class ProductPhotoBox extends StatelessWidget {
  const ProductPhotoBox({super.key, required this.path, required this.onPick});

  final String path;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPick,
      child: Container(
        height: 160,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFD1D5DB)),
        ),
        clipBehavior: Clip.antiAlias,
        child: path.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined, size: 38),
                    SizedBox(height: 8),
                    Text('Add product photo'),
                  ],
                ),
              )
            : Image.file(File(path), fit: BoxFit.cover),
      ),
    );
  }
}

class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD1D5DB)),
      ),
      clipBehavior: Clip.antiAlias,
      child: path.isEmpty
          ? const Icon(Icons.image_outlined)
          : Image.file(File(path), fit: BoxFit.cover),
    );
  }
}

class FeatureRow extends StatelessWidget {
  const FeatureRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(body),
      ),
    );
  }
}

Future<void> openNewOrder(
  BuildContext context, {
  String initialPhotoPath = '',
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => NewOrderScreen(initialPhotoPath: initialPhotoPath),
    ),
  );
}

Future<void> openOrderDetails(BuildContext context, SenoOrder order) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => OrderDetailsScreen(orderId: order.id)),
  );
}

Future<String?> takeSharedPhotoPath() async {
  if (!Platform.isAndroid) return null;
  try {
    return await shareChannel.invokeMethod<String>('takeSharedImage');
  } catch (_) {
    return null;
  }
}

Future<ImageSource?> chooseImageSource(BuildContext context) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    builder: (context) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Gallery'),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
}

Future<void> showEditOrderForm(BuildContext context, SenoOrder order) async {
  final store = StoreScope.of(context);
  final customer = TextEditingController(text: order.customerName);
  final phone = TextEditingController(text: order.phone);
  final address = TextEditingController(text: order.address);
  final notes = TextEditingController(text: order.notes);
  var receiptMethod = order.receiptMethod;
  final formKey = GlobalKey<FormState>();

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Edit order'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: customer,
                  decoration: const InputDecoration(labelText: 'Customer name'),
                  validator: requiredText,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'Shipment',
                      label: Text('Shipment'),
                      icon: Icon(Icons.local_shipping_outlined),
                    ),
                    ButtonSegment(
                      value: 'Pickup',
                      label: Text('Pickup'),
                      icon: Icon(Icons.store_outlined),
                    ),
                  ],
                  selected: {receiptMethod},
                  onSelectionChanged: (value) =>
                      setDialogState(() => receiptMethod = value.first),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: address,
                  decoration: const InputDecoration(labelText: 'Address'),
                  minLines: 2,
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  minLines: 2,
                  maxLines: 4,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              order.customerName = customer.text.trim();
              order.phone = phone.text.trim();
              order.receiptMethod = receiptMethod;
              order.address = address.text.trim();
              order.notes = notes.text.trim();
              order.status = order.derivedStatus;
              await store.updateOrder(order);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  customer.dispose();
  phone.dispose();
  address.dispose();
  notes.dispose();
}

Future<void> showEditProductForm(
  BuildContext context,
  SenoOrder order, [
  SenoOrderItem? item,
]) async {
  final store = StoreScope.of(context);
  final picker = ImagePicker();
  final name = TextEditingController(text: item?.productName ?? '');
  final origin = TextEditingController(
    text: item == null ? '' : money(item.originPrice),
  );
  final customer = TextEditingController(
    text: item == null ? '' : money(item.customerPrice),
  );
  final notes = TextEditingController(text: item?.notes ?? '');
  var photoPath = item?.photoPath ?? '';
  var officeId = item?.officeId;
  var status = item?.status ?? 'Pending reservation';
  if ((officeId == null || officeId.isEmpty) && store.offices.isNotEmpty) {
    officeId = store.offices.first.id;
  }
  final formKey = GlobalKey<FormState>();

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(item == null ? 'Add product' : 'Edit product'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProductPhotoBox(
                  path: photoPath,
                  onPick: () async {
                    final source = await chooseImageSource(context);
                    if (source == null) return;
                    final picked = await picker.pickImage(
                      source: source,
                      imageQuality: 78,
                    );
                    if (picked != null) {
                      setDialogState(() => photoPath = picked.path);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Product name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: officeId,
                  decoration: const InputDecoration(labelText: 'Office'),
                  items: store.offices
                      .map(
                        (office) => DropdownMenuItem(
                          value: office.id,
                          child: Text(office.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setDialogState(() => officeId = value),
                  validator: (value) => value == null ? 'Select office' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: origin,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Origin price',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: customer,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Customer price',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: productStatuses
                      .map(
                        (status) => DropdownMenuItem(
                          value: status,
                          child: Text(status),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => status = value ?? status),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Product notes'),
                  minLines: 2,
                  maxLines: 4,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final updated = SenoOrderItem(
                id: item?.id ?? newId(),
                productName: name.text.trim().isEmpty
                    ? 'Product'
                    : name.text.trim(),
                photoPath: photoPath,
                officeId: officeId ?? store.offices.first.id,
                originPrice: parseMoney(origin.text),
                customerPrice: parseMoney(customer.text),
                status: status,
                notes: notes.text.trim(),
              );
              if (item == null) {
                order.items.add(updated);
              } else {
                final index = order.items.indexWhere(
                  (existing) => existing.id == item.id,
                );
                if (index >= 0) order.items[index] = updated;
              }
              order.status = order.derivedStatus;
              await store.updateOrder(order);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  origin.dispose();
  customer.dispose();
  notes.dispose();
}

Future<void> showDeliverySettings(BuildContext context) async {
  final store = StoreScope.of(context);
  final phone = TextEditingController(text: store.deliveryPhone);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delivery WhatsApp'),
      content: TextField(
        controller: phone,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          labelText: 'Delivery phone',
          helperText: 'Used when sending customer address details.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            await store.updateDeliveryPhone(phone.text);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  phone.dispose();
}

Future<void> showOfficeForm(BuildContext context, {Office? office}) async {
  final store = StoreScope.of(context);
  final name = TextEditingController(text: office?.name ?? '');
  final phone = TextEditingController(text: office?.phone ?? '');
  final notes = TextEditingController(text: office?.notes ?? '');
  final formKey = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(office == null ? 'Add office' : 'Edit office'),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Office name'),
                validator: requiredText,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'WhatsApp phone'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Notes'),
                minLines: 2,
                maxLines: 4,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (!formKey.currentState!.validate()) return;
            final updated = Office(
              id: office?.id ?? newId(),
              name: name.text.trim(),
              phone: phone.text.trim(),
              notes: notes.text.trim(),
            );
            if (office == null) {
              await store.addOffice(updated);
            } else {
              await store.updateOffice(updated);
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  name.dispose();
  phone.dispose();
  notes.dispose();
}

Future<void> sendOfficeReservation(
  BuildContext context,
  Office office,
  List<OrderItemMatch> matches,
) async {
  final store = StoreScope.of(context);
  final lines = [
    'Seno reservation request',
    'Office: ${office.name}',
    '',
    ...matches.map(
      (match) =>
          '- ${match.item.productName} | Customer: ${match.order.customerName} | Price: ${money(match.item.customerPrice)}',
    ),
  ];
  final message = lines.join('\n');
  await store.markOfficeReservationSent(office.id, matches, message);
  if (!context.mounted) return;
  await openWhatsAppOrCopy(context, office.phone, message);
}

Future<void> showReservationHistory(BuildContext context, Office office) async {
  final store = StoreScope.of(context);
  final batches = store.batchesForOffice(office.id);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${office.name} reservations'),
      content: SizedBox(
        width: double.maxFinite,
        child: batches.isEmpty
            ? const Text('No reservations sent yet.')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: batches.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, index) {
                  final batch = batches[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${shortDate(batch.sentAt)} | ${batch.itemIds.length} products',
                    ),
                    subtitle: Text(
                      batch.message,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy message',
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: batch.message),
                        );
                        if (context.mounted) showSnack(context, 'Copied.');
                      },
                      icon: const Icon(Icons.copy),
                    ),
                  );
                },
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

Future<void> sendDeliveryMessage(BuildContext context, SenoOrder order) async {
  final store = StoreScope.of(context);
  final items = order.items.map((item) => '- ${item.productName}').join('\n');
  final message = [
    'Delivery details',
    'Customer: ${order.customerName}',
    'Phone: ${order.phone}',
    'Receive: ${order.receiptMethod}',
    'Address: ${order.address}',
    '',
    'Products:',
    items,
    '',
    'Total: ${money(order.total)}',
    'Paid: ${money(order.paidAmount)}',
    'Remaining: ${money(order.remaining)}',
  ].join('\n');
  final targetPhone = store.deliveryPhone.isEmpty
      ? order.phone
      : store.deliveryPhone;
  await openWhatsAppOrCopy(context, targetPhone, message);
}

Future<void> openWhatsAppOrCopy(
  BuildContext context,
  String phone,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: message));
  final normalizedPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  final uri = normalizedPhone.isEmpty
      ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}')
      : Uri.parse(
          'https://wa.me/$normalizedPhone?text=${Uri.encodeComponent(message)}',
        );
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (context.mounted) {
    showSnack(
      context,
      opened ? 'Message copied and WhatsApp opened.' : 'Message copied.',
    );
  }
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String? requiredText(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return null;
}

double parseMoney(String value) {
  return double.tryParse(value.trim().replaceAll(',', '.')) ?? 0;
}

String money(double value) {
  return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2);
}

String shortDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}-$month-$day $hour:$minute';
}

String blank(String value) => value.trim().isEmpty ? '-' : value.trim();

String newId() => DateTime.now().microsecondsSinceEpoch.toString();
