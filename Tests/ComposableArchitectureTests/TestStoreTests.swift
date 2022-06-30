import Combine
import ComposableArchitecture
import XCTest

//@MainActor
class TestStoreTests: XCTestCase {
  func testEffectConcatenation() async {
    struct State: Equatable {}

    enum Action: Equatable {
      case a, b1, b2, b3, c1, c2, c3, d
    }

    let mainQueue = DispatchQueue.test

    let reducer = Reducer<State, Action, AnySchedulerOf<DispatchQueue>> { _, action, scheduler in
      switch action {
      case .a:
        return .merge(
          Effect.concatenate(.init(value: .b1), .init(value: .c1))
            .delay(for: 1, scheduler: scheduler)
            .eraseToEffect(),
          Empty(completeImmediately: false)
            .eraseToEffect()
            .cancellable(id: 1)
        )
      case .b1:
        return
          Effect
          .concatenate(.init(value: .b2), .init(value: .b3))
      case .c1:
        return
          Effect
          .concatenate(.init(value: .c2), .init(value: .c3))
      case .b2, .b3, .c2, .c3:
        return .none

      case .d:
        return .cancel(id: 1)
      }
    }

    let store = TestStore(
      initialState: State(),
      reducer: reducer,
      environment: mainQueue.eraseToAnyScheduler()
    )

    store.send(.a)

    await mainQueue.advance(by: 1)

    await store.receive(.b1)
    await store.receive(.b2)
    await store.receive(.b3)

    await store.receive(.c1)
    await store.receive(.c2)
    await store.receive(.c3)

    store.send(.d)
  }

  func testAsync() async {
    enum Action: Equatable {
      case tap
      case response(Int)
    }
    let store = TestStore(
      initialState: 0,
      reducer: Reducer<Int, Action, Void> { state, action, _ in
        switch action {
        case .tap:
          return .task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            return .response(42)
          }
        case let .response(number):
          state = number
          return .none
        }
      },
      environment: ()
    )

    store.send(.tap)
    await store.receive(.response(42), timeout: 2_000_000) {
      $0 = 42
    }
  }

  func testExpectedStateEquality() {
    struct State: Equatable {
      var count: Int = 0
      var isChanging: Bool = false
    }

    enum Action: Equatable {
      case increment
      case changed(from: Int, to: Int)
    }

    let reducer = Reducer<State, Action, Void> { state, action, scheduler in
      switch action {
      case .increment:
        state.isChanging = true
        return Effect(value: .changed(from: state.count, to: state.count + 1))
      case .changed(let from, let to):
        state.isChanging = false
        if state.count == from {
          state.count = to
        }
        return .none
      }
    }

    let store = TestStore(
      initialState: State(),
      reducer: reducer,
      environment: ()
    )

    store.send(.increment) {
      $0.isChanging = true
    }
    store.receive(.changed(from: 0, to: 1)) {
      $0.isChanging = false
      $0.count = 1
    }

    XCTExpectFailure {
      _ = store.send(.increment) {
        $0.isChanging = false
      }
    }
    XCTExpectFailure {
      store.receive(.changed(from: 1, to: 2)) {
        $0.isChanging = true
        $0.count = 1100
      }
    }
  }

  func testExpectedStateEqualityMustModify() {
    struct State: Equatable {
      var count: Int = 0
    }

    enum Action: Equatable {
      case noop, finished
    }

    let reducer = Reducer<State, Action, Void> { state, action, scheduler in
      switch action {
      case .noop:
        return Effect(value: .finished)
      case .finished:
        return .none
      }
    }

    let store = TestStore(
      initialState: State(),
      reducer: reducer,
      environment: ()
    )

    store.send(.noop)
    store.receive(.finished)

    XCTExpectFailure {
      _ = store.send(.noop) {
        $0.count = 0
      }
    }
    XCTExpectFailure {
      store.receive(.finished) {
        $0.count = 0
      }
    }
  }

  func testStateAccess() {
    enum Action { case a, b, c, d }
    let store = TestStore(
      initialState: 0,
      reducer: Reducer<Int, Action, Void> { count, action, _ in
        switch action {
        case .a:
          count += 1
          return .merge(.init(value: .b), .init(value: .c), .init(value: .d))
        case .b, .c, .d:
          count += 1
          return .none
        }
      },
      environment: ()
    )

    store.send(.a) {
      $0 = 1
      XCTAssertEqual(store.state, 0)
    }
    XCTAssertEqual(store.state, 1)
    store.receive(.b) {
      $0 = 2
      XCTAssertEqual(store.state, 1)
    }
    XCTAssertEqual(store.state, 2)
    store.receive(.c) {
      $0 = 3
      XCTAssertEqual(store.state, 2)
    }
    XCTAssertEqual(store.state, 3)
    store.receive(.d) {
      $0 = 4
      XCTAssertEqual(store.state, 3)
    }
    XCTAssertEqual(store.state, 4)
  }


  @MainActor
  func testNonDeterministicActions() async {
    struct State: Equatable {
      var count1 = 0
      var count2 = 0
    }
    enum Action { case tap, response1, response2 }
    let store = TestStore(
      initialState: State(),
      reducer: Reducer<State, Action, Void> { state, action, _ in
        switch action {
        case .tap:
          return .merge(
            .task { .response1 },
            .task { .response2 }
          )
        case .response1:
          state.count1 = 1
          return .none
        case .response2:
          state.count2 = 2
          return .none
        }
      },
      environment: ()
    )

    store.send(.tap)
    await store.receive(.response1) {
      $0.count1 = 1
    }
    await store.receive(.response2) {
      $0.count2 = 2
    }
  }

  @MainActor
  func testSerialExecutor() async {
    struct State: Equatable {
      var count = 0
    }
    enum Action: Equatable {
      case tap
      case response(Int)
    }
    let store = TestStore(
      initialState: State(),
      reducer: Reducer<State, Action, Void> { state, action, _ in
        switch action {
        case .tap:
          return .run { send in
            await withTaskGroup(of: Void.self) { group in
              for index in 1...5 {
                group.addTask {
                  await send(.response(index))
                }
              }
            }
          }
        case let .response(value):
          state.count += value
          return .none
        }
      },
      environment: ()
    )

    store.send(.tap)
    await store.receive(.response(1)) {
      $0.count = 1
    }
    await store.receive(.response(2)) {
      $0.count = 3
    }
    await store.receive(.response(3)) {
      $0.count = 6
    }
    await store.receive(.response(4)) {
      $0.count = 10
    }
    await store.receive(.response(5)) {
      $0.count = 15
    }
  }
}
