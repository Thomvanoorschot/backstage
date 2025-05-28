This repository contains an experimental implementation of an actor framework, serving as both a learning exercise and a practical exploration of actor-based concurrent programming patterns.

## Project Overview

The main goal of this project is to gain deeper understanding of the programming language while building something practical and useful. By implementing an actor framework from scratch, this project explores:

- Concurrent programming patterns
- Message passing between actors
- Actor lifecycle management
- State isolation and encapsulation

## Installation

Use fetch:

```bash
zig fetch --save https://github.com/Thomvanoorschot/backstage/archive/main.tar.gz
```

Or add backstage to your build.zig.zon:

```zig
.dependencies = .{
    .backstage = .{
        .url = "https://github.com/Thomvanoorschot/backstage/archive/main.tar.gz",
        .hash = "...", // Update with actual hash
    },
},
```

## Learning Focus

This project emphasizes:
- Understanding language-specific features and idioms
- Implementing concurrent programming patterns
- Building a maintainable and extensible codebase
- Practical application of software design principles

## Current Status

This is an early-stage implementation, focusing on core actor framework concepts. The project is primarily meant as a learning exercise and may evolve significantly as understanding of both the language and actor patterns deepens.

## Goals

- Implement basic actor messaging system
- Explore actor supervision hierarchies
- Adding some sort of co-routine system to allow for async operations
- Add a network layer to allow for actor discovery and communication between nodes
- Create a foundation for potential future development