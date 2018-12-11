require 'omniauth-oauth2'

module ::OmniAuth
  module OpenIDConnect
    class DiscoveryError < Error; end
  end

  module Strategies
    class OpenIDConnect < OmniAuth::Strategies::OAuth2
      option :scope, "openid"
      option :discovery, true
      option :use_userinfo, true
      option :cache, lambda { |key, &blk| blk.call } # Default no-op cache
      option :error_handler, lambda { |error, message| nil } # Default no-op handler
      option :passthrough_authorize_options, [:p]
      option :passthrough_token_options, [:p]

      option :client_options,
        discovery_document: nil,
        site: nil,
        authorize_url: nil,
        token_url: nil,
        userinfo_endpoint: nil,
        auth_scheme: :basic_auth,
        callback_url: "https://chat.havenclaims.co.uk/auth/oidc/callback"

      def discover!
        debug("Beginning Discovery Phase.")
        
        discovery_document = options.cache.call("openid_discovery_#{options[:client_options][:discovery_document]}") do
          client.request(:get, options[:client_options][:discovery_document], parse: :json).parsed
        end

        discovery_params = {
          authorize_url: "authorization_endpoint",
          token_url: "token_endpoint",
          site: "issuer"
        }

        discovery_params.each do |internal_key, external_key|
          val = discovery_document[external_key].to_s
          raise ::OmniAuth::OpenIDConnect::DiscoveryError.new("missing discovery parameter #{external_key}") if val.nil? || val.empty?
          options[:client_options][internal_key] = val
        end

        userinfo_endpoint = options[:client_options][:userinfo_endpoint] = discovery_document["userinfo_endpoint"].to_s
        options.use_userinfo = false if userinfo_endpoint.nil? || userinfo_endpoint.empty?
        
        debug("User Endpoint: #{discovery_document["userinfo_endpoint"].to_s}")
      end

      def request_phase
        begin
          debug("Beginning Request Phase")
          discover! if options[:discovery]
        rescue ::OmniAuth::OpenIDConnect::DiscoveryError => e
          fail!(:openid_connect_discovery_error, e)
        end

        super
      end

      def authorize_params
        super.tap do |params|
          options[:passthrough_authorize_options].each do |k|
            params[k] = request.params[k.to_s] unless [nil, ''].include?(request.params[k.to_s])
          end

          params[:scope] = options[:scope]
          session['omniauth.nonce'] = params[:nonce] = SecureRandom.hex(32)

          options[:passthrough_token_options].each do |k|
            session["omniauth.param.#{k}"] = request.params[k.to_s] unless [nil, ''].include?(request.params[k.to_s])
          end
        end
      end

      def token_params
        params = {}
        options[:passthrough_token_options].each do |k|
          val = session.delete("omniauth.param.#{k}")
          params[k] = val unless [nil, ''].include?(val)
        end
        super.merge(params)
      end

      def callback_phase
        if request.params["error"] && request.params["error_description"] && response = options.error_handler.call(request.params["error"], request.params["error_description"])
          return redirect(response)
        end

        begin
          discover! if options[:discovery]

          oauth2_callback_phase = super
          return oauth2_callback_phase if env['omniauth.error']

          if id_token_info["nonce"].nil? || id_token_info["nonce"].empty? || id_token_info["nonce"] != session.delete("omniauth.nonce")
            return fail!(:csrf_detected, CallbackError.new(:csrf_detected, "CSRF detected"))
          end
          oauth2_callback_phase
        rescue ::OmniAuth::OpenIDConnect::DiscoveryError => e
          fail!(:openid_connect_discovery_error, e)
        rescue JWT::DecodeError => e
          fail!(:jwt_decode_failed, e)
        end
      end

      def id_token_info
        # Verify the claims in the JWT
        # The signature does not need to be verified because the
        # token was acquired via a direct server-server connection to the issuer
        @id_token_info ||= JWT.decode(
          access_token['id_token'], nil, false,
            :verify_iss => true,
            'iss' => options[:client_options][:site],
            :verify_aud => true,
            'aud' => options.client_id,
            :verify_sub => false,
            :verify_expiration => true,
            :verify_not_before => true,
            :verify_iat => true,
            :verify_jti => false
          ).first
      end

      def userinfo_response
        @raw_info ||= access_token.get(options[:client_options][:userinfo_endpoint]).parsed
        return fail!(:csrf_detected, CallbackError.new(:csrf_detected, "CSRF detected")) unless @raw_info['sub'] == id_token_info['sub']
        @raw_info
      end

      uid { id_token_info['sub'] }

      ##debug("Extracting User Info")
      info do
        data_source = options.use_userinfo ? userinfo_response : id_token_info
        prune!(
          name: data_source['name'],
          email: data_source['email'],
          first_name: data_source['given_name'],
          last_name: data_source['family_name'],
          nickname: data_source['preferred_username'],
          picture: data_source['picture']
        )
      end

      extra do
        hash = {}
        hash[:raw_info] = options.use_userinfo ? userinfo_response : id_token_info
        prune! hash
      end

      private

      def callback_url
        full_host + script_name + callback_path
        debug("Callback URL Compiled to: #{full_host + script_name + callback_path}")
      end

      def get_token_options
        { redirect_uri: callback_url,
          grant_type: 'authorization_code',
          code: request.params["code"],
          client_id: options[:client_id],
          client_secret: options[:client_secret]
        }.merge(token_params.to_hash(symbolize_keys: true))
      end

      def prune!(hash)
        hash.delete_if do |_, v|
          prune!(v) if v.is_a?(Hash)
          v.nil? || (v.respond_to?(:empty?) && v.empty?)
        end
      end

      protected

      def build_access_token
        return super if options.use_userinfo
        response = client.request(:post, options[:client_options][:token_url], body: get_token_options)
        ::OAuth2::AccessToken.from_hash(client, response.parsed)
      end
                   
      def debug(info)
        Rails.logger.warn("OpenID Debug: #{info}") if SiteSetting.openid_debug_auth
      end

    end
  end
end

OmniAuth.config.add_camelization 'openid_connect', 'OpenIDConnect'
