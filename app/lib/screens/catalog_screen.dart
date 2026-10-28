import 'package:flutter/material.dart';

import 'products_screen.dart';
import 'stock_screen.dart';

/// Products and Stock under one tab.
class CatalogScreen extends StatelessWidget {
  final VoidCallback onChanged;
  const CatalogScreen({super.key, required this.onChanged});

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
