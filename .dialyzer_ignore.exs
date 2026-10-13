[
  # Gettext 1.0 + Expo 1.1 generate a `Gettext.Plural.plural/2` call against
  # Expo's opaque `PluralForms` struct inside the backend that
  # `use Gettext.Backend` generates. A false positive in code this module
  # does not author; scoped to the backend file and that one warning type.
  {"lib/phoenix_kit_sync/gettext.ex", :call_without_opaque},
  # MapSet opaque type false positives - Dialyzer can't properly track
  # MapSet opaque types through recursive topo_sort/visit_node functions
  ~r/lib\/phoenix_kit_sync\/web\/connections_live\.ex:.*call_without_opaque/,
  ~r/lib\/phoenix_kit_sync\/web\/connections_live\.ex:.*opaque/
]
