import 'package:flutter/material.dart';

/// "Back to the home screen" action for a staff console's app bar.
///
/// Every console is a stack of pages pushed on top of the one the role gate
/// mounted - the supervisor console, the admin dashboard - and two or three levels
/// down (monitor -> analytics, picker -> monitor -> analytics) the only way back
/// used to be the platform's back gesture. That gesture does not exist in a
/// browser, which is one of the two targets this app ships to, so each console's
/// app bars carry this instead.
///
/// Popping to the *first* route is what makes it work from any depth without every
/// page having to know which console it belongs to: the first route is the landing
/// page by construction (see `RoleGate`). On the landing page itself there is
/// nothing to pop, so the button stays put rather than disappearing - one
/// affordance, in the same place, in every console.
class HomeButton extends StatelessWidget {
  const HomeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Home',
      onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
      icon: const Icon(Icons.home_outlined),
    );
  }
}
