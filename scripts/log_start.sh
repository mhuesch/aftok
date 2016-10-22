#!/bin/bash

read -p "Username: " USER
echo
read -p "Project ID: " PID
read -p "User ID: " UID

curl -v -k -u $USER -X POST -d "{\"schemaVersion\": \"2.0\", \"creditTo\": {\"creditToUser\": \"$UID\"}}" "https://aftok.com/projects/$PID/logStart"
