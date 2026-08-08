/// Category icons, addressed by stable name.
///
/// Categories store an icon *name*, not a code point. Flutter's release builds
/// tree-shake icon fonts down to the glyphs it can prove are used, and an
/// `IconData` constructed from a runtime integer is invisible to that
/// analysis — it renders as a blank box in release while looking fine in
/// debug. Every icon here is a const reference, so all of them survive.
library;

import 'package:flutter/material.dart';

const Map<String, IconData> _byName = {
  'tag': Icons.sell_outlined,
  'shopping_cart': Icons.shopping_cart_outlined,
  'restaurant': Icons.restaurant_outlined,
  'coffee': Icons.local_cafe_outlined,
  'directions_transit': Icons.directions_transit_outlined,
  'directions_car': Icons.directions_car_outlined,
  'flight': Icons.flight_outlined,
  'bike': Icons.pedal_bike_outlined,
  'home': Icons.home_outlined,
  'bolt': Icons.bolt_outlined,
  'wifi': Icons.wifi_outlined,
  'phone': Icons.smartphone_outlined,
  'subscriptions': Icons.subscriptions_outlined,
  'favorite': Icons.favorite_outline,
  'medication': Icons.medication_outlined,
  'fitness': Icons.fitness_center_outlined,
  'shopping_bag': Icons.shopping_bag_outlined,
  'checkroom': Icons.checkroom_outlined,
  'movie': Icons.movie_outlined,
  'sports_esports': Icons.sports_esports_outlined,
  'music': Icons.music_note_outlined,
  'book': Icons.menu_book_outlined,
  'school': Icons.school_outlined,
  'pets': Icons.pets_outlined,
  'child': Icons.child_care_outlined,
  'gift': Icons.card_giftcard_outlined,
  'savings': Icons.savings_outlined,
  'payments': Icons.payments_outlined,
  'work': Icons.work_outline,
  'build': Icons.build_outlined,
  'local_bar': Icons.local_bar_outlined,
  'spa': Icons.spa_outlined,
};

/// The icon for [name], falling back to a neutral tag when a backup restored
/// on an older build references an icon this version does not know.
IconData iconFor(String name) => _byName[name] ?? Icons.sell_outlined;

/// Every selectable icon name, for the category editor's picker.
List<String> get allIconNames => _byName.keys.toList(growable: false);

/// The palette offered when creating a category.
///
/// Chosen to stay distinguishable both against each other in a pie chart and
/// against light and dark backgrounds.
const List<int> categoryPalette = [
  0xFF4CAF50, // green
  0xFF66BB6A, // light green
  0xFF26A69A, // teal
  0xFF42A5F5, // blue
  0xFF5C6BC0, // indigo
  0xFF7E57C2, // deep purple
  0xFFAB47BC, // purple
  0xFFEC407A, // pink
  0xFFEF5350, // red
  0xFFFF7043, // deep orange
  0xFFFFA726, // orange
  0xFFFFCA28, // amber
  0xFF8D6E63, // brown
  0xFF78909C, // blue grey
];
