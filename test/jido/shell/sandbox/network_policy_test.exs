defmodule Jido.Shell.Sandbox.NetworkPolicyTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Sandbox.NetworkPolicy

  describe "enforce/2" do
    test "returns :ok for unparsable command lines" do
      assert :ok = NetworkPolicy.enforce(~s(curl "unterminated), %{})
    end

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

    test "supports port blocklist checks" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          block_ports: [443]
        }
      }

      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce("curl https://example.com:443", context)

      assert message =~ "port 443 is blocklisted"
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

    test "extracts bare host targets for allowlist checks" do
      assert :ok =
               NetworkPolicy.enforce(
                 "curl example.com/path",
                 %{network: %{allow_domains: ["example.com"]}}
               )
    end

    test "supports short port flags" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          allow_ports: [8443]
        }
      }

      assert :ok = NetworkPolicy.enforce("curl -p 8443 example.com", context)
    end

    test "supports long port flags" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          allow_ports: [9443]
        }
      }

      assert :ok = NetworkPolicy.enforce("curl --port=9443 example.com", context)
    end

    test "rejects commands when allow_domains are set but no target domain is found" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce(
                 "curl --silent",
                 %{network: %{allow_domains: ["example.com"]}}
               )

      assert message =~ "unable to determine target domain"
    end

    test "rejects commands when allow_ports are set but no target port is found" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce(
                 "curl example.com",
                 %{network: %{allow_ports: [443]}}
               )

      assert message =~ "unable to determine target port"
    end

    test "rejects domains with non-allowlisted ports" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}, message: message}} =
               NetworkPolicy.enforce(
                 "curl https://example.com:80",
                 %{network: %{allow_domains: ["example.com"], allow_ports: [443]}}
               )

      assert message =~ "port 80 is not allowlisted"
    end

    test "supports bracketed host:port endpoints" do
      assert :ok =
               NetworkPolicy.enforce(
                 "curl [2001:db8::1]:8080",
                 %{network: %{allow_domains: ["2001:db8::1"], allow_ports: [8080]}}
               )
    end

    test "accepts keyword-style execution contexts and string defaults" do
      context = [
        network: [
          default: "allow"
        ]
      ]

      assert :ok = NetworkPolicy.enforce("curl https://example.com", context)
    end

    test "ignores invalid configured ports" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          allow_ports: ["abc", -1, 999_999, 8443]
        }
      }

      assert :ok = NetworkPolicy.enforce("curl --port=8443 example.com", context)
    end

    test "treats non-keyword list contexts as empty config" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce("curl https://example.com", [:invalid])
    end

    test "enforces policy across chained commands" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce(
                 "echo safe; curl https://example.com",
                 %{network: %{default: :deny}}
               )
    end

    test "ignores non-network commands" do
      assert :ok = NetworkPolicy.enforce("echo https://example.com", %{})
    end
  end
end
