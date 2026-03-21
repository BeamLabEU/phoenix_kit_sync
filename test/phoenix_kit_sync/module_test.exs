defmodule PhoenixKitSync.ModuleTest do
  use ExUnit.Case, async: true

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitSync.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitSync.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns sync" do
      assert PhoenixKitSync.module_key() == "sync"
    end

    test "module_name/0 returns Sync" do
      assert PhoenixKitSync.module_name() == "Sync"
    end

    test "enabled?/0 returns false when DB unavailable" do
      # Rescues internally and returns false since no DB in unit tests
      refute PhoenixKitSync.enabled?()
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitSync, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitSync, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitSync.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitSync.permission_metadata()
      assert meta.key == PhoenixKitSync.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitSync.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = PhoenixKitSync.admin_tabs()
      assert is_list(tabs)
      assert tabs != []
    end

    test "main tab has required fields" do
      [tab | _] = PhoenixKitSync.admin_tabs()
      assert tab.id == :admin_sync
      assert tab.label == "Sync"
      assert is_binary(tab.path)
      assert tab.level == :admin
      assert tab.permission == PhoenixKitSync.module_key()
      assert tab.group == :admin_modules
    end

    test "all tabs have permission matching module_key" do
      for tab <- PhoenixKitSync.admin_tabs() do
        assert tab.permission == PhoenixKitSync.module_key()
      end
    end

    test "all subtabs reference parent" do
      [main | subtabs] = PhoenixKitSync.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "all tab IDs are namespaced with admin_sync" do
      for tab <- PhoenixKitSync.admin_tabs() do
        assert tab.id |> to_string() |> String.starts_with?("admin_sync"),
               "Tab ID #{tab.id} should start with admin_sync"
      end
    end

    test "tab paths use hyphens not underscores" do
      for tab <- PhoenixKitSync.admin_tabs() do
        refute String.contains?(tab.path, "_"),
               "Tab path #{tab.path} contains underscores — use hyphens"
      end
    end

    test "main tab has live_view for route generation" do
      [tab | _] = PhoenixKitSync.admin_tabs()
      assert {PhoenixKitSync.Web.Index, :index} = tab.live_view
    end
  end

  describe "version/0" do
    test "returns version string" do
      assert PhoenixKitSync.version() == "0.1.0"
    end
  end

  describe "optional callbacks" do
    test "get_config/0 is exported" do
      assert function_exported?(PhoenixKitSync, :get_config, 0)
    end

    test "children/0 returns a list" do
      children = PhoenixKitSync.children()
      assert is_list(children)
    end

    test "route_module/0 returns Routes module" do
      assert PhoenixKitSync.route_module() == PhoenixKitSync.Routes
    end
  end
end
