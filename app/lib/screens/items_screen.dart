import 'package:flutter/material.dart';

import 'products_screen.dart';
import 'stock_screen.dart';

/// Products and Stock side by side, so the bottom bar has room for Customers.
class ItemsScreen extends StatelessWidget {
  final VoidCallback onChanged;
  const ItemsScreen({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        const TabBar(tabs: [Tab(text: 'Products'), Tab(text: 'Stock')]),
        Expanded(
          child: TabBarView(children: [
            ProductsScreen(onChanged: onChanged),
            const StockScreen(),
          ]),
        ),
      ]),
    );
  }
}
