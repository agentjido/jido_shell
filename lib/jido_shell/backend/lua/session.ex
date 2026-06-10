defmodule Jido.Shell.Backend.Lua.Session do
  @moduledoc """
  Holder process for a persistent immutable `%Lua{}` state.

  The GenServer only stores and commits Lua state. Evaluation happens in the
  caller process so timeout and cancellation can kill runaway Lua code without
  pinning the holder.
  """

  use GenServer

  alias Jido.Shell.Backend.Lua.JidoApi
  alias Jido.Shell.Error

  @type eval_context :: map()

  def new(%Lua{} = lua) do
    GenServer.start_link(__MODULE__, lua)
  end

  def eval(pid, script, context) when is_pid(pid) and is_binary(script) and is_map(context) do
    with {:ok, lua} <- checkout(pid) do
      do_eval(pid, lua, script, context)
    end
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(%Lua{} = lua), do: {:ok, lua}

  @impl true
  def handle_call(:checkout, _from, lua) do
    {:reply, {:ok, lua}, lua}
  end

  def handle_call({:commit, %Lua{} = lua}, _from, _old_lua) do
    {:reply, :ok, lua}
  end

  defp checkout(pid) do
    GenServer.call(pid, :checkout)
  catch
    :exit, reason -> {:error, Error.command(:crashed, %{reason: reason})}
  end

  defp commit(pid, %Lua{} = lua) do
    GenServer.call(pid, {:commit, lua})
  catch
    :exit, reason -> {:error, Error.command(:crashed, %{reason: reason})}
  end

  defp do_eval(pid, %Lua{} = lua, script, context) do
    lua = Lua.put_private(lua, JidoApi.context_key(), context)

    {_return, new_lua} = Lua.eval!(lua, script)
    final_context = final_context(new_lua, context)
    clean_lua = Lua.delete_private(new_lua, JidoApi.context_key())

    with :ok <- commit(pid, clean_lua) do
      {:ok, state_update(context, final_context)}
    end
  rescue
    error in [Lua.CompilerException] ->
      {:error, Error.command(:syntax_error, %{line: script, reason: Exception.message(error)})}

    error in [Lua.RuntimeException] ->
      {:error, Error.command(:runtime_error, %{line: script, reason: Exception.message(error)})}

    error ->
      {:error, Error.command(:crashed, %{line: script, reason: Exception.message(error)})}
  catch
    :throw, {:lua_output_limit_exceeded, %Error{} = error} ->
      {:error, error}

    kind, reason ->
      {:error, Error.command(:crashed, %{line: script, reason: {kind, reason}})}
  end

  defp final_context(%Lua{} = lua, fallback) do
    case Lua.get_private(lua, JidoApi.context_key()) do
      {:ok, context} when is_map(context) -> context
      _ -> fallback
    end
  end

  defp state_update(initial, final) do
    changes =
      %{}
      |> maybe_put_change(:cwd, Map.get(initial, :cwd), Map.get(final, :cwd))
      |> maybe_put_change(:env, Map.get(initial, :env), Map.get(final, :env))

    if map_size(changes) == 0 do
      nil
    else
      {:state_update, changes}
    end
  end

  defp maybe_put_change(changes, _key, value, value), do: changes

  defp maybe_put_change(changes, key, _old_value, new_value) do
    Map.put(changes, key, new_value)
  end
end
