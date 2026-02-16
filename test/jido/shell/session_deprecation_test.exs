defmodule Jido.Shell.SessionDeprecationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "Session shim emits deprecation warning" do
    warning = compile_with_warning("Jido.Shell.Session.generate_id()")
    assert warning =~ "Jido.Shell.Session.generate_id/0 is deprecated"
    assert warning =~ "Use Jido.Shell.ShellSession.generate_id/0"
  end

  test "SessionServer shim emits deprecation warning" do
    warning = compile_with_warning("Jido.Shell.SessionServer.get_state(\"sess-missing\")")
    assert warning =~ "Jido.Shell.SessionServer.get_state/1 is deprecated"
    assert warning =~ "Use Jido.Shell.ShellSessionServer.get_state/1"
  end

  test "Session.State shim emits deprecation warning" do
    warning = compile_with_warning("Jido.Shell.Session.State.schema()")
    assert warning =~ "Jido.Shell.Session.State.schema/0 is deprecated"
    assert warning =~ "Use Jido.Shell.ShellSession.State.schema/0"
  end

  defp compile_with_warning(call) do
    module_name =
      Module.concat(__MODULE__, :"Deprecated#{System.unique_integer([:positive, :monotonic])}")

    source = """
    defmodule #{inspect(module_name)} do
      def run do
        #{call}
      end
    end
    """

    capture_io(:stderr, fn ->
      Code.compile_string(source)
    end)
  end
end
