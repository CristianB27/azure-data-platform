variable "deploy_expensive" {
  description = "true = desplegar recursos costosos; false = destruirlos"
  type        = bool
  default     = false
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "prefix" {
  type    = string
  default = "p09utb"
}

variable "temperature_threshold" {
  description = "Umbral de alerta de temperatura"
  type        = number
  default     = 30
}

variable "synapse_admin_password" {
  description = "Password del admin SQL de Synapse (viene de variable secreta del pipeline)"
  type        = string
  sensitive   = true
}