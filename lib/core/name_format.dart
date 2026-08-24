/// The shortest respectful name to use in a dashboard greeting.
///
/// Profiles store one free-form full name rather than separate given/family
/// fields. Taking the last non-empty word follows the product decision to keep
/// the greeting compact without inventing a first-name field the data does not
/// have. An all-uppercase stored name is softened for display only.
String addressName(String fullName) {
  final parts = fullName
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'there';

  final last = parts.last;
  if (last != last.toUpperCase()) return last;
  if (last.length == 1) return last;
  return '${last[0].toUpperCase()}${last.substring(1).toLowerCase()}';
}
