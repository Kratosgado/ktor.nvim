package com.example.routing

import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Route.userRoutes() {
    route("/users") {
        get("/{id}") {
            call.respond("user")
        }
    }
}
