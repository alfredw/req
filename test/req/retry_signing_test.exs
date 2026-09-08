defmodule Req.RetrySigningTest do
  use Req.Case, async: true

  test "signing an unchanged request again preserves its signature" do
    for token <- [nil, "session-token"] do
      request = request(token)
      once = Req.Steps.put_aws_sigv4(request)
      twice = Req.Steps.put_aws_sigv4(once)
      assert twice.headers == once.headers
    end
  end

  test "resigning uses the current body, timestamp and session credentials" do
    request = request("old-token")
    signed = Req.Steps.put_aws_sigv4(request)

    options = [
      body: "new bytes",
      aws_sigv4: [
        access_key_id: "new-access",
        secret_access_key: "new-secret",
        token: "new-token",
        service: :s3,
        region: "us-east-1",
        datetime: ~U[2026-09-07 01:00:00Z]
      ]
    ]

    fresh = request |> Req.merge(options) |> Req.Steps.put_aws_sigv4()
    retried = signed |> Req.merge(options) |> Req.Steps.put_aws_sigv4()
    assert retried.headers == fresh.headers
  end

  test "an HTTP retry sends a signature matching the original request" do
    parent = self()

    %{req: req, url: url} =
      serve_sequence(
        "PUT /object": fn conn ->
          send(parent, {:first_signature, get_req_header(conn, "authorization")})
          send_resp(conn, 503, "unavailable")
        end,
        "PUT /object": fn conn ->
          send(parent, {:retry_signature, get_req_header(conn, "authorization")})
          send_resp(conn, 200, "stored")
        end
      )

    response =
      Req.put!(req,
        url: "#{url}/object",
        body: "immutable",
        aws_sigv4: request("session-token").options.aws_sigv4,
        retry: :transient,
        retry_delay: 0,
        max_retries: 1
      )

    assert response.status == 200
    assert response.body == "stored"
    assert_receive {:first_signature, [signature]}
    assert_receive {:retry_signature, [^signature]}
  end

  defp request(token) do
    Req.new(
      method: :put,
      url: "http://localhost/bucket/object",
      body: "immutable",
      aws_sigv4: [
        access_key_id: "access",
        secret_access_key: "secret",
        token: token,
        service: :s3,
        region: "us-east-1",
        datetime: ~U[2026-09-07 00:00:00Z]
      ]
    )
  end
end
