defmodule Jido.Shell.Sandbox.NetworkPolicyTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Sandbox.NetworkPolicy

  describe "enforce/2" do
    test "blocks network commands by default" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce("curl https://example.com", %{})

      assert message =~ "denied by default"
    end

    test "allows allowlisted domain" do
      assert :ok =
               NetworkPolicy.enforce(
                 "curl https://example.com",
                 %{network: %{allow_domains: ["example.com"]}}
               )
    end

    test "blocks non-allowlisted domain" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce(
                 "curl https://bad.example.com",
                 %{network: %{allow_domains: ["example.com"]}}
               )

      assert message =~ "not allowlisted"
    end

    test "blocklist wins over allowlist" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          block_domains: ["example.com"]
        }
      }

      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce("curl https://example.com", context)

      assert message =~ "blocklisted"
    end

    test "supports port allowlist checks" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          allow_ports: [8080]
        }
      }

      assert :ok = NetworkPolicy.enforce("curl http://example.com:8080", context)
    end

    test "ignores non-network commands" do
      assert :ok = NetworkPolicy.enforce("echo https://example.com", %{})
    end
  end
end
