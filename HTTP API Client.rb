class CurrencyRates
  API = 'https://api.ratesapi.io/api/latest'
  
  def initialize
    response = HttpRequest.get(API)
    fx = JSON.parse(response.body)
    
    @rates = fx["rates"]
  end
  
  def eur_to_usd(eur)
    (eur / @rates["USD"]).round(2)
  end
end

fx = CurrencyRates.new
puts fx.eur_to_usd(150.50)
