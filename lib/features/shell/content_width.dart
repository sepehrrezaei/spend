import 'package:flutter/material.dart';

/// Constrains page content to a comfortable reading width.
///
/// A list stretched across a maximised 27-inch display puts a transaction's
/// amount most of a metre from its label, and the eye cannot connect the two.
/// Desktop apps constrain their content and let the window grow around it.
class ContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ContentWidth({required this.child, this.maxWidth = 860, super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
