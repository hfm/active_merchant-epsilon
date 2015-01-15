require 'nokogiri'
require 'active_support/core_ext/string'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class EpsilonGateway < Gateway
      self.test_url = 'https://beta.epsilon.jp/cgi-bin/order/'
      self.live_url = 'https://secure.epsilon.jp/cgi-bin/order/'

      self.supported_countries = ['JP']
      self.default_currency = 'JPY'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      self.homepage_url = 'http://www.example.net/'
      self.display_name = 'New Gateway'

      # Allow access ActiveMerchant::Connection properties(proxy_address and proxy_port).
      # see: https://github.com/Shopify/active_utils/blob/master/lib/active_utils/common/connection.rb#L34-L35
      cattr_accessor :contract_code, :proxy_address, :proxy_port

      PATHS = {
        purchase: 'direct_card_payment.cgi',
        registered_recurring: 'direct_card_payment.cgi',
        cancel_recurring: 'receive_order3.cgi',
        void: 'cancel_payment.cgi'
      }.freeze

      module ResponseXpath
        RESULT = '//Epsilon_result/result[@result]/@result'
        TRANSACTION_CODE = '//Epsilon_result/result[@trans_code]/@trans_code'
        ERROR_CODE = '//Epsilon_result/result[@err_code]/@err_code'
        ERROR_DETAIL = '//Epsilon_result/result[@err_detail]/@err_detail'
      end

      module MissionCode
        # クレジット1回、またはクレジット決済以外の場合
        PURCHASE = 1

        # | CODE | 登録月 | 解除月 | 同月内での登録解除 |
        # | 2    | 全額   | 無料   | 1ヶ月分            |
        # | 3    | 全額   | 全額   | 1ヶ月分            |
        # | 4    | 全額   | 日割   | 1ヶ月分            |
        # | 5    | 無料   | 無料   | 無料               |
        # | 6    | 無料   | 全角   | 1ヶ月分            |
        # | 7    | 無料   | 日割   | 日割               |
        # | 8    | 日割   | 無料   | 日割               |
        # | 9    | 日割   | 全額   | 1ヶ月分            |
        # | 10   | 日割   | 日割   | 日割               |
        RECURRING_2 = 2
        RECURRING_3 = 3
        RECURRING_4 = 4
        RECURRING_5 = 5
        RECURRING_6 = 6
        RECURRING_7 = 7
        RECURRING_8 = 8
        RECURRING_9 = 9
        RECURRING_10 = 10

        RECURRINGS = (2..10).to_a.freeze
      end

      def initialize(options={})
        super
      end

      # def purchase(money, payment_method, detail = {})
      #   path = case payment_method
      #     when CreditCard
      #       'direct_card_payment.cgi'
      #     when ConvenienceStore
      #       'receive_order3.cgi'
      #     end
      #
      #   params = case payment_method
      #     when CreditCard
      #       {
      #         contract_code: detail[:contract_code],
      #         user_id: detail[:user_id],
      #         user_name: payment_method.name,
      #         user_mail_add: detail[:user_email],
      #         item_code: detail[:item_code],
      #         item_name: detail[:item_name],
      #         order_number: detail[:order_number],
      #         st_code: '10000-0000-0000',
      #         mission_code: 1,
      #         item_price: money,
      #         process_code: 1,
      #         card_number: payment_method.number,
      #         expire_y: payment_method.year,
      #         expire_m: payment_method.month,
      #         user_agent: 'test'
      #       }
      #     when ConvenienceStore
      #       {
      #         contract_code: detail[:contract_code],
      #         user_id: detail[:user_id],
      #         user_name: payment_method.name,
      #         user_mail_add: detail[:user_email],
      #         item_code: detail[:item_code],
      #         item_name: detail[:item_name],
      #         order_number: detail[:order_number],
      #         st_code: '00100-0000-0000',
      #         mission_code: 1,
      #         item_price: money,
      #         process_code: 1,
      #         conveni_code: payment_method.code,
      #         user_name_kana: payment_method.name,
      #         user_tel: payment_method.phone_number,
      #         xml: 1,
      #         user_agent: 'test'
      #       }
      #     else
      #       {} # TODO
      #   end
      #
      #   commit(path, params)
      # end

      def purchase(amount, payment_method, detail = {})
        detail[:process_code] = 1
        detail[:mission_code] = MissionCode::PURCHASE

        case payment_method
        when CreditCard
          action = 'purchase'
          params = billing_params(amount, payment_method, detail)
        when ConvenienceStore
          # TODO
          raise 'do NOT work yet'
        else
          # TODO
          raise 'do NOT work yet'
        end

        commit(action, params)
      end

      def recurring(amount, credit_card, detail = {})
        detail[:process_code] = 1
        detail[:mission_code] ||= MissionCode::RECURRING_2

        requires!(detail, [:mission_code, *MissionCode::RECURRINGS])

        params = billing_params(amount, credit_card, detail)

        commit('purchase', params)
      end

      def registered_recurring(amount, detail = {})
        commit(
          'registered_recurring',
          contract_code: self.contract_code,
          user_id: detail[:user_id],
          user_name: detail[:user_name],
          user_mail_add: detail[:user_email],
          item_code: detail[:item_code],
          item_name: detail[:item_name],
          order_number: detail[:order_number],
          st_code: '10000-0000-0000',
          mission_code: detail[:mission_code],
          item_price: amount,
          process_code: 2,
          xml: 1
        )
      end

      def cancel_recurring(user_id:, item_code:)
        commit(
          'cancel_recurring',
          contract_code: self.contract_code,
          user_id: user_id,
          item_code: item_code,
          xml: 1,
          process_code: 8
        )
      end

      def authorize(money, payment, options={})
        raise
      end

      def capture(money, authorization, options={})
        raise
      end

      def refund(money, authorization, options={})
        raise
      end

      def void(order_number)
        commit(
          'void',
          contract_code: self.contract_code,
          order_number: order_number
        )
      end

      def verify(credit_card, options={})
        o = options.dup
        o[:order_number] ||= "#{Time.now.to_i}#{options[:user_id]}".first(32)
        o[:item_code] = 'verifycreditcard'
        o[:item_name] = 'verify credit card'

        MultiResponse.run(:use_first_response) do |r|
          r.process { purchase(1, credit_card, o) }
          r.process(:ignore_result) { void(o[:order_number]) }
        end
      end

      private

      def parse(body)
        xml = Nokogiri::XML(body.sub('x-sjis-cp932', 'CP932'))

        success = xml.xpath(ResponseXpath::RESULT).to_s == '1'
        transaction_code = xml.xpath(ResponseXpath::TRANSACTION_CODE).to_s
        error_code = xml.xpath(ResponseXpath::ERROR_CODE).to_s
        error_detail = URI.decode(
          xml.xpath(ResponseXpath::ERROR_DETAIL).to_s
        ).encode(Encoding::UTF_8, Encoding::CP932)

        {
          success: success,
          message: "#{error_code}: #{error_detail}",
          transaction_code: transaction_code,
          error_code: error_code,
          error_detail: error_detail
        }
      end

      def commit(action, parameters)
        url = (test? ? test_url : live_url)

        path = PATHS[action.to_sym]

        response = parse(ssl_post(url + path, post_data(parameters)))

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?
        )
      end

      # Override ActiveMerchant::PostsData#raw_ssl_request
      # see: https://github.com/Shopify/active_utils/blob/master/lib/active_utils/common/posts_data.rb#L39
      def raw_ssl_request(method, endpoint, data, headers = {})
        logger.warn "#{self.class} using ssl_strict=false, which is insecure" if logger unless ssl_strict

        connection = new_connection(endpoint)
        connection.open_timeout = open_timeout
        connection.read_timeout = read_timeout
        connection.retry_safe   = retry_safe
        connection.verify_peer  = ssl_strict
        connection.ssl_version  = ssl_version
        connection.logger       = logger
        connection.max_retries  = max_retries
        connection.tag          = self.class.name
        connection.wiredump_device = wiredump_device

        connection.pem          = @options[:pem] if @options
        connection.pem_password = @options[:pem_password] if @options

        connection.ignore_http_status = @options[:ignore_http_status] if @options

        connection.proxy_address = proxy_address
        connection.proxy_port = proxy_port
        connection.request(method, data, headers)
      end

      def success_from(response)
        response[:success]
      end

      def message_from(response)
        response[:message]
      end

      def billing_params(amount, credit_card, detail)
        {
          contract_code: detail[:contract_code] || self.contract_code,
          user_id: detail[:user_id],
          user_name: credit_card.name,
          user_mail_add: detail[:user_email],
          item_code: detail[:item_code],
          item_name: detail[:item_name],
          order_number: detail[:order_number],
          st_code: '10000-0000-0000',
          mission_code: detail[:mission_code],
          item_price: amount,
          process_code: detail[:process_code],
          card_number: credit_card.number,
          expire_y: credit_card.year,
          expire_m: credit_card.month,
          user_agent: "#{ActiveMerchant::Epsilon}-#{ActiveMerchant::Epsilon::VERSION}",
        }
      end

      def authorization_from(response)
        {}
      end

      def post_data(parameters = {})
        parameters.map {|k, v| "#{k}=#{CGI.escape(v.to_s)}"}.join('&')
      end
    end
  end
end
