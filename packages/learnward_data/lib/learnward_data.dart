/// Infrastructure adapters for LearnWard.
///
/// Contains Drift/SQLite persistence, Supabase repositories, DTO mapping and
/// sync adapters as later phases implement them. Domain rules do not belong
/// here.
library;

export 'src/database/app_database.dart';
