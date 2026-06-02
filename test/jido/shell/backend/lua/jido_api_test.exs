defmodule Jido.Shell.Backend.Lua.JidoApiTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.Lua.JidoApi
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = "lua_api_ws_#{System.unique_integer([:positive])}"
    fs_name = "lua_api_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    on_exit(fn -> VFS.unmount(workspace_id, "/") end)

    {:ok, workspace_id: workspace_id}
  end

  defp lua_with_context(workspace_id, opts \\ []) do
    parent = self()
    ref = make_ref()

    emit = fn event ->
      send(parent, {ref, event})
      :ok
    end

    context = %{
      session_id: "lua-api-test",
      workspace_id: workspace_id,
      cwd: Keyword.get(opts, :cwd, "/"),
      env: Keyword.get(opts, :env, %{}),
      execution_context: %{},
      emit: emit
    }

    lua =
      Lua.new()
      |> Lua.load_api(JidoApi)
      |> JidoApi.install_globals()
      |> Lua.put_private(JidoApi.context_key(), context)

    {lua, ref}
  end

  defp collect_events(ref, acc \\ []) do
    receive do
      {^ref, event} -> collect_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "jido command arguments preserve parser separators and escapes", %{workspace_id: wid} do
    {lua, ref} = lua_with_context(wid)

    Lua.eval!(lua, ~S|jido.echo("foo;bar", "one&&two", "quote\"here", "path\\name")|)

    assert [{:output, ~s(foo;bar one&&two quote"here path\\name\n)}] = collect_events(ref)
  end

  test "state updates propagate to later jido calls in the same eval", %{workspace_id: wid} do
    :ok = VFS.mkdir(wid, "/work")
    {lua, ref} = lua_with_context(wid)

    {_result, lua} = Lua.eval!(lua, ~S|jido.cd("/work"); jido.pwd()|)

    assert [{:output, "/work\n"}] = collect_events(ref)
    assert {:ok, %{cwd: "/work"}} = Lua.get_private(lua, JidoApi.context_key())
  end

  test "command errors emit stderr and raise Lua runtime errors", %{workspace_id: wid} do
    {lua, ref} = lua_with_context(wid)

    assert_raise Lua.RuntimeException, fn ->
      Lua.eval!(lua, ~S|jido.cat("/missing.txt")|)
    end

    assert [{:output_stderr, stderr}] = collect_events(ref)
    assert stderr =~ "not_found"
  end
end
