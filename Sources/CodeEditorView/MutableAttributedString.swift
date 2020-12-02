//
//  MutableAttributedString.swift
//  
//
//  Created by Manuel M T Chakravarty on 03/11/2020.
//
//  Extensions to `NSMutableAttributedString`

import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif


private let logger = Logger(subsystem: "org.justtesting.CodeEditor", category: "MutableAttributedString")


// MARK: -
// MARK: Regular expression-based tokenisers with explicit state management for context-free constructs

/// Token descriptions
///
enum TokenPattern: Hashable, Equatable, Comparable {

  /// The token has only one lexeme, given as a simple string
  ///
  case string(String)

  /// The token has multiple lexemes, specified in the form of a regular expression string
  ///
  case pattern(String)
}

protocol TokeniserState {

  /// Finite projection of tokeniser state to determine sub-tokenisers (and hence, the regular expression to use)
  ///
  associatedtype StateTag: Hashable

  /// Project the tag out of a full state
  ///
  var tag: StateTag { get }
}

/// Actions taken in response to matching a token
///
/// The `token` component determines the token type of the matched pattern and `transition` determines the state
/// transition implied by the matched token. If the `transition` component is `nil`, the tokeniser stays in the current
/// state.
///
typealias TokenAction<TokenType, StateType> = (token: TokenType, transition: ((StateType) -> StateType)?)

/// For each possible state tag of the underlying tokeniser state, a mapping from token patterns to token kinds and
/// maybe a state transition to determine a new tokeniser state
///
typealias TokenDictionary<TokenType, StateType: TokeniserState>
  = [StateType.StateTag: [TokenPattern: TokenAction<TokenType, StateType>]]

/// Pre-compiled regular expression tokeniser
///
/// The `TokenType` is identifies the various tokens that can be recognised by the tokeniser.
///
struct Tokeniser<TokenType, StateType: TokeniserState> {

  /// Tokeniser for one state of the compound tokeniser
  ///
  struct State {

    /// The matching regular expression
    ///
    let regexp: NSRegularExpression

    /// The lookup table for single-lexeme tokens
    ///
    let stringTokenTypes: [String: TokenAction<TokenType, StateType>]

    /// The token types for multi-lexeme tokens
    ///
    /// The order of the token types in the array is the same as that of the matching groups for those tokens in the
    /// regular expression.
    ///
    let patternTokenTypes: [TokenAction<TokenType, StateType>]
  }

  /// Sub-tokeniser for all states of the compound tokeniser
  ///
  let states: [StateType.StateTag: State]
}

extension NSMutableAttributedString {

  /// Create a tokeniser from the given token dictionary.
  ///
  /// - Parameter tokenMap: The token dictionary determining the lexemes to match and their token type.
  /// - Returns: A tokeniser that matches all lexemes contained in the token dictionary.
  ///
  /// The tokeniser is based on an eager regular expression matcher. Hence, it will match the first matching alternative
  /// in a sequence of alternatives. To deal with string patterns, where some patterns may be a prefix of another, the
  /// string patterns are turned into regular expression alternatives longest string first. However, pattern consisting
  /// of regular expressions are tried in an indeterminate order. Hence, no pattern should have as a full match a prefix
  /// of another pattern's full match, to avoid indeterminate results.
  ///
  static func tokeniser<TokenType, StateType: TokeniserState>(for tokenMap: TokenDictionary<TokenType, StateType>)
  -> Tokeniser<TokenType, StateType>?
  {
    func tokeniser(for stateMap: [TokenPattern: TokenAction<TokenType, StateType>])
    throws -> Tokeniser<TokenType, StateType>.State
    {

      // NB: Be careful with the re-ordering, because the order in `patternTokenTypes` below must match the order of
      //     the patterns in the laternatives of the regular expression. (We must re-order due to eager matching as
      //     explained in the documentation of this function.)
      let orderedMap = stateMap.sorted{ (lhs, rhs) in return lhs.key > rhs.key },
          pattern    = orderedMap.reduce("") { (regexp, mapEntry) in

            let regexpPattern: String
            switch mapEntry.key {
            case .string(let lexeme):   regexpPattern = NSRegularExpression.escapedPattern(for: lexeme)
            case .pattern(let pattern): regexpPattern = "(" + pattern + ")"     // each pattern gets a capture group
            }
            if regexp.isEmpty { return regexpPattern } else { return regexp + "|" + regexpPattern}
          }
      let stringTokenTypes: [(String, TokenAction<TokenType, StateType>)] = orderedMap.compactMap{ (pattern, type) in
        if case .string(let lexeme) = pattern { return (lexeme, type)  } else { return nil }
      }
      let patternTokenTypes: [TokenAction<TokenType, StateType>] = orderedMap.compactMap{ (pattern, type) in
        if case .pattern(_) = pattern { return type } else { return nil }
      }

      let regexp = try NSRegularExpression(pattern: pattern, options: [])
      return Tokeniser.State(regexp: regexp,
                             stringTokenTypes: [String: TokenAction<TokenType, StateType>](stringTokenTypes){
                              (left, right) in return left },
                             patternTokenTypes: patternTokenTypes)
    }

    do {

      let states = try tokenMap.mapValues{ try tokeniser(for: $0) }
      return Tokeniser(states: states)

    } catch let err { logger.error("failed to compile regexp: \(err.localizedDescription)"); return nil }
  }

  /// Parse the given range and set the corresponding token attribute values on all matching lexeme ranges.
  ///
  /// - Parameters:
  ///   - attribute: The custom attribute key that identifies token attributes.
  ///   - tokeniser: Pre-compiled tokeniser.
  ///   - startState: Starting state of the tokeniser.
  ///   - range: The range in the receiver that is to be parsed and attributed.
  ///
  /// All previously existing occurences of `attribute` in the given range are removed.
  ///
  func tokeniseAndSetTokenAttribute<TokenType, StateType>(attribute: NSAttributedString.Key,
                                                          with tokeniser: Tokeniser<TokenType, StateType>,
                                                          state startState: StateType,
                                                          in range: NSRange)
  {
    var state        = startState
    var currentRange = range

    // Clear existing attributes
    removeAttribute(attribute, range: range)

    // Tokenise and set appropriate attributes
    while currentRange.length > 0 {

      guard let stateTokeniser = tokeniser.states[state.tag],
            let result         = stateTokeniser.regexp.firstMatch(in: self.string, options: [], range: currentRange)
      else { break }  // no more match => stop

      // The next lexeme we look for from just after the one we just found
      currentRange = NSRange(location: NSMaxRange(result.range),
                             length: currentRange.length - NSMaxRange(result.range) + currentRange.location)

      // If a matching group in the regexp matched, select the action of the correpsonding pattern.
      var tokenAction: TokenAction<TokenType, StateType>?
      for i in stride(from: result.numberOfRanges - 1, through: 1, by: -1) {

        if result.range(at: i).location != NSNotFound { // match by a capture group => complex pattern match

          tokenAction = stateTokeniser.patternTokenTypes[i - 1]
        }
      }

      // If it wasn't a matching group, it must be a simple string match
      if tokenAction == nil {                           // no capture group matched => we matched a simple string lexeme

        tokenAction = stateTokeniser.stringTokenTypes[(self.string as NSString).substring(with: result.range)]
      }

      if let action = tokenAction {

        // Set the token attribute on the lexeme range
        self.addAttribute(attribute, value: action.token, range: result.range)

        // If there is an associated state transition function, apply it to the tokeniser state
        if let transition = action.transition { state = transition(state) }

      }
    }
  }
}
