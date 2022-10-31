
# Show simple alerts 
Alert("Mail Alert!", "Make sure to check your mail.")

# Prompt and Confirm are additional helpers classes to display simple Alerts.
if Confirm("Do you want to proceed with this action?")
  # Execute dangerous code
end

name = Prompt("What's your name?", "Name")
puts "Hello, #{name}! Nice to meet you."

# Create and configure a advanced alert-based interactions
alert = Alert.new do |a|
  a.title = "Who are you?"
  a.message = "Tell me more about yourself."

  a.add_textfield("Name")
  a.add_number_textfield("Age")
  a.add_email_textfield("Email")

  a.add_action("Submit")
  a.add_cancel_action("Cancel")
end

# Present the alert to the user
alert.present()

# The alert object will be updated with the response
if alert.selected_action.title == "Submit"
  name = alert.textfields["Name"].text
  age = alert.textfields["Age"].text
  email = alert.textfields["Email"].text

  puts "Hey #{name}! You are #{age} years old and your email is #{email}"
end